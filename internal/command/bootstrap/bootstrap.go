package bootstrap

import (
	"errors"
	"log/slog"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/spf13/cobra"
)

var errNoRepo = errors.New("no remote Git repository specified")

// helpDescription is the description printed when the command is run with the
// `--help` flag.
//
//nolint:gochecknoglobals,lll // It is easier to have this here instead of inlining.
var helpDescription = `Bootstrap clones the specified dotfiles directory and runs the initial installation.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:               constants.BootstrapCommandName + " [flags]",
		Aliases:           []string{"clone", "init", "initialise", "initialize"},
		Short:             "Ask " + constants.Name + " to bootstrap your environment",
		Long:              strutil.Cap(helpDescription, constants.HelpLineLen),
		Args:              cobra.MaximumNArgs(1),
		Annotations:       docsAnnotations(),
		PersistentPreRunE: persistentPreRun,
		RunE:              run,
	}

	return cmd
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

	cfg.Repository = repo

	return nil
}

func run(cmd *cobra.Command, _ []string) error {
	slog.Info("Running the command", "cmd", constants.BootstrapCommandName)

	cfg, ok := cmd.Context().Value(config.ConfigContextKey).(*config.Config)
	if !ok || cfg == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoConfig))
	}

	slog.Debug("Got the Config instance from context", slog.Any("cfg", cfg))
	slog.Info("Received the repository config", "repository", cfg.Repository)

	return nil
}
