// Package bootstrap contains the `bootstrap` command of the program.
package bootstrap

import (
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"strings"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/git"
	"github.com/anttikivi/reginald/internal/output"
	"github.com/anttikivi/reginald/internal/paths"
	"github.com/anttikivi/reginald/internal/runner"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	errFileExists  = errors.New("file already exists at the base directory path")
	errNoRepo      = errors.New("no remote Git repository specified")
	errInvalidRepo = errors.New("invalid remote Git repository")
)

// helpDescription is the description printed when the command is run with the
// `--help` flag.
//
//nolint:gochecknoglobals,lll // It is easier to have this here instead of inlining.
var helpDescription = `Bootstrap clones the specified dotfiles directory and runs the initial installation. It accepts two positional arguments, the remote repository and the directory where it should be cloned to, in that order. You can also specify those using the other configuration sources, please consult the documentation on configuration. Giving the remote repository and the directory using the positional arguments always takes precedence.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`

// NewCommand creates a new instance of the bootstrap command.
//
//nolint:lll // Cannot really make the help messages shorter.
func NewCommand(vpr *viper.Viper) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:               constants.BootstrapCommandName + " [repository] [directory]",
		Aliases:           []string{"clone", "init", "initialise", "initialize", "setup"},
		Short:             "Ask " + constants.Name + " to bootstrap your environment",
		Long:              strutil.Cap(helpDescription, constants.HelpLineLen),
		Args:              cobra.MaximumNArgs(2), //nolint:mnd // Not really that magic of a number.
		Annotations:       docsAnnotations(),
		PersistentPreRunE: persistentPreRun,
		RunE:              run,
		SilenceUsage:      true,
	}

	cmd.Flags().String(
		"host",
		config.DefaultRepositoryHostname,
		"hostname to use for cloning the remote dotfiles repository if the given repository is not a full URL",
	)
	config.BindString(vpr, cmd, config.KeyRepositoryHostname, "host")
	cmd.Flags().String(
		"protocol",
		config.DefaultGitProtocol.String(),
		"protocol used in cloning the remote dotfiles repository if the given repository is not a full URL",
	)
	config.BindString(vpr, cmd, config.KeyGitProtocol, "protocol")
	cmd.Flags().String(
		"ssh-user",
		config.DefaultGitSSHUser,
		"SSH user used in cloning the remote dotfiles repository if the given repository is not a full URL and SSH is used for cloning",
	)
	config.BindString(vpr, cmd, config.KeyGitSSHUser, "ssh-user")
	cmd.Flags().Bool(
		"disable-https-init",
		config.DefaultDisableHTTPSInit,
		"disable cloning the repository using HTTPS during the bootstrapping even if the program was set to use SSH (see the documentation for further information)",
	)

	if err := vpr.BindPFlag(config.KeyDisableHTTPSInit, cmd.Flags().Lookup("disable-https-init")); err != nil {
		return nil, fmt.Errorf(
			"failed to bind the flag \"disable-https-init\" to config %q: %w",
			config.KeyDisableHTTPSInit,
			err,
		)
	}

	return cmd, nil
}

func persistentPreRun(cmd *cobra.Command, args []string) error {
	slog.Info("Running the persistent pre-run", "cmd", constants.BootstrapCommandName)

	cfg, ok := cmd.Context().Value(config.ConfigContextKey).(*config.Config)
	if !ok || cfg == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoConfig))
	}

	slog.Debug("Got the Config instance from context", slog.Any("cfg", cfg))

	repoArg := ""

	if len(args) > 0 {
		repoArg = args[0]
	}

	repo := repoArg
	if repo == "" {
		repo = cfg.Repository
	}

	if repo == "" {
		return exit.New(exit.InvalidConfig, errNoRepo)
	}

	repo, err := parseRepo(repo, cfg)
	if err != nil {
		return exit.New(exit.InvalidConfig, fmt.Errorf("%w", err))
	}

	slog.Debug("Parsed the remote repository URL", "url", repo)

	cfg.Repository = repo

	dirArg := ""

	if len(args) > 1 {
		dirArg = args[1]
	}

	if dirArg != "" {
		dirArg, err = paths.Abs(dirArg)
		if err != nil {
			return exit.New(
				exit.InvalidConfig,
				fmt.Errorf("failed to turn the given directory to an absolute path: %w", err),
			)
		}

		cfg.BaseDirectory = dirArg
	}

	return nil
}

func parseRepo(repo string, cfg *config.Config) (string, error) {
	isURL := strings.Contains(repo, ":")

	if !isURL {
		var err error

		repo, err = parseURLFromName(repo, cfg)
		if err != nil {
			return "", fmt.Errorf("%w", err)
		}
	}

	repo = strings.TrimPrefix(repo, "ssh://")

	u, err := parseURL(repo)
	if err != nil {
		return "", fmt.Errorf("failed to parse the repository URL: %w", err)
	}

	repoURL := simplifyRepoURL(u)

	return repoURL.String(), nil
}

func parseURLFromName(repo string, cfg *config.Config) (string, error) {
	isFullName := strings.Contains(repo, "/")

	var fullName string

	if isFullName {
		fullName = repo
	} else {
		host := cfg.RepositoryHostname

		if host == "" {
			return "", fmt.Errorf("%w: no hostname provided", errNoRepo)
		}

		// NOTE: This is in no way a complete solution but, for now, require a
		// full repository name for at least GitHub and GitLab as I know that
		// they require the repository to be `name/repo`. Otherwise it might be
		// sufficient to assume the given name is complete, as the Git host can
		// be really anything.
		if strings.Contains(host, "github") || strings.Contains(host, "gitlab") {
			return "", fmt.Errorf("%w: full repository name not given for %s", errNoRepo, host)
		}

		fullName = repo
	}

	switch cfg.GitProtocol {
	case git.SSH:
		// This parses to a full SSH URL in the next step.
		repo = fmt.Sprintf("%s@%s:%s", cfg.GitSSHUser, cfg.RepositoryHostname, fullName)
	case git.HTTPS:
		repo = fmt.Sprintf("%s://%s/%s", cfg.GitProtocol.String(), cfg.RepositoryHostname, fullName)
	default:
		return "", fmt.Errorf("%w: %v", git.ErrInvalidProtocol, cfg.GitProtocol)
	}

	if !strings.HasSuffix(repo, ".git") {
		repo += ".git"
	}

	return repo, nil
}

func isSupportedProtocol(s string) bool {
	return strings.HasPrefix(s, "ssh:") || strings.HasPrefix(s, "git+ssh:") || strings.HasPrefix(s, "git:") ||
		strings.HasPrefix(s, "http:") ||
		strings.HasPrefix(s, "git+https:") ||
		strings.HasPrefix(s, "https:")
}

func isPossibleProtocol(s string) bool {
	return isSupportedProtocol(s) || strings.HasPrefix(s, "ftp:") || strings.HasPrefix(s, "ftps:") ||
		strings.HasPrefix(s, "file:")
}

func parseURL(s string) (*url.URL, error) {
	if !isPossibleProtocol(s) && strings.Contains(s, ":") && !strings.Contains(s, "\\") {
		s = "ssh://" + strings.Replace(s, ":", "/", 1)
	}

	u, err := url.Parse(s)
	if err != nil {
		return nil, fmt.Errorf("%w", err)
	}

	switch u.Scheme {
	case "git+https":
		u.Scheme = "https"
	case "git+ssh":
		u.Scheme = "ssh"
	}

	if u.Scheme != "ssh" {
		return u, nil
	}

	if strings.HasPrefix(u.Path, "//") {
		u.Path = strings.TrimPrefix(u.Path, "/")
	}

	u.Host = strings.TrimSuffix(u.Host, ":"+u.Port())

	return u, nil
}

// simplifyRepoURL strips given URL of extra parts like extra path segments
// (i.e., anything beyond `/owner/repo`), query strings, or fragments.
//
// The rationale behind this function is to let users clone a repo with any
// URL related to the repo; like:
//   - (Tree)              github.com/owner/repo/blob/main/foo/bar
//   - (Deep-link to line) github.com/owner/repo/blob/main/foo/bar#L168
//   - (Issue/PR comment)  github.com/owner/repo/pull/999#issue-9999999999
//   - (Commit history)    github.com/owner/repo/commits/main/?author=foo
func simplifyRepoURL(u *url.URL) *url.URL {
	result := &url.URL{ //nolint:exhaustruct // Only the values set are necessary.
		Scheme: u.Scheme,
		User:   u.User,
		Host:   u.Host,
		Path:   u.Path,
	}

	pathParts := strings.SplitN(strings.Trim(u.Path, "/"), "/", 3) //nolint:mnd // Not really a magic number.
	if len(pathParts) <= 2 {                                       //nolint:mnd // Not really a magic number.
		return result
	}

	result.Path = strings.Join(pathParts[0:2], "/")

	return result
}

func run(cmd *cobra.Command, _ []string) error {
	slog.Info("Running the command", "cmd", constants.BootstrapCommandName)

	cfg, ok := cmd.Context().Value(config.ConfigContextKey).(*config.Config)
	if !ok || cfg == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoConfig))
	}

	slog.Debug("Got the Config instance from context", slog.Any("cfg", cfg))

	p, ok := cmd.Context().Value(config.PrinterContextKey).(*output.Printer)
	if !ok || p == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoPrinter))
	}

	slog.Debug("Got the Printer instance from context", slog.Any("printer", p))

	r, ok := cmd.Context().Value(config.RunnerContextKey).(*runner.Runner)
	if !ok || r == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoRunner))
	}

	slog.Debug("Got the Runner instance from context", slog.Any("runner", r))

	slog.Info("Received the repository config", "repository", cfg.Repository)

	repo := cfg.Repository
	if strings.HasPrefix(repo, "ssh://") && !cfg.DisableHTTPSInit {
		slog.Debug("Converting the repository to HTTPS for cloning")

		repo, err := toHTTPS(repo)
		if err != nil {
			return exit.New(exit.InvalidConfig, fmt.Errorf("cannot convert repository from SSH to HTTPS: %w", err))
		}

		slog.Debug("Conversion done", "repository", repo)
	}

	slog.Debug("Checking if the directory exists", "dir", cfg.BaseDirectory)

	exists, err := paths.Exists(cfg.BaseDirectory)
	if err != nil {
		return exit.New(exit.InvalidConfig, fmt.Errorf("%w", err))
	}

	if exists {
		p.RedErrorf("The file at %s already exists\n", cfg.BaseDirectory)

		return exit.New(exit.InvalidConfigFile, fmt.Errorf("%w: %s", errFileExists, cfg.BaseDirectory))
	}

	return nil
}

func toHTTPS(repo string) (string, error) {
	repo = strings.TrimPrefix(repo, "ssh://")

	// Remove `user@`.
	i := strings.IndexByte(repo, '@')
	if i == -1 {
		return "", fmt.Errorf("%w: no '@' found", errInvalidRepo)
	}

	repo = repo[i+1:]

	// This should suffice as the URL was "normalized" earlier.
	repo = "https://" + repo

	return repo, nil
}
