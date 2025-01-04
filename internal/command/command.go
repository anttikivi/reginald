package command

import (
	"fmt"
	"log/slog"

	"github.com/anttikivi/reginald/internal/command/bootstrap"
	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// helpDescription is the description printed when the command is run with the
// `--help` flag.
//
//nolint:gochecknoglobals,lll // It is easier to have this here instead of inlining.
var helpDescription = constants.Name + ` is the workstation valet for managing your workstation configuration and installed tools. It can bootstrap your local workstation, keep your "dotfiles" up to date by managing symlinks to them, and take care of whatever task you want to. To use ` + constants.Name + `, call one of the commands or read the man page for more information.

Please note that ` + constants.Name + ` is still in development, and not all of the promised feature are implemented.`

// New creates a new instance of the root command which includes the
// subcommands.
// TODO: Thinking that maybe the context should be passed in here.
func New(vpr *viper.Viper, ver string) (*cobra.Command, error) {
	cobra.EnableTraverseRunHooks = true

	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:               constants.CommandName + " command [flags]",
		Short:             constants.Name + " is the workstation valet",
		Long:              strutil.Cap(helpDescription, constants.HelpLineLen),
		Annotations:       docsAnnotations(),
		Version:           ver,
		PersistentPreRunE: persistentPreRun,
		RunE:              runHelp,
	}

	cmd.SetVersionTemplate(version.Template(ver))

	if err := addFlags(cmd); err != nil {
		return nil, fmt.Errorf("%w", err)
	}

	if err := vpr.BindPFlag(config.KeyColor, cmd.PersistentFlags().Lookup("color")); err != nil {
		return nil, fmt.Errorf("failed to bind the flag \"color\" to config %q: %w", config.KeyColor, err)
	}

	cmd.AddCommand(bootstrap.NewCommand())
	cmd.AddCommand(version.NewCommand(ver))

	return cmd, nil
}

func addFlags(cmd *cobra.Command) error {
	cmd.PersistentFlags().Bool("color", false, "explicitly enable colors in the command-line output")
	cmd.PersistentFlags().Bool("no-color", false, "disable colors in the command-line output")
	cmd.MarkFlagsMutuallyExclusive("color", "no-color")

	if err := cmd.PersistentFlags().MarkHidden("no-color"); err != nil {
		return fmt.Errorf("failed to mark the \"no-color\" flag as hidden: %w", err)
	}

	cmd.PersistentFlags().StringP("config-file", "c", "", "path to config file")

	if err := cmd.MarkPersistentFlagFilename("config-file", "json", "toml", "yaml", "yml"); err != nil {
		return fmt.Errorf("failed to mark the \"config-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().StringP("directory", "C", config.DefaultDirectory, "path to the local dotfiles directory")

	if err := cmd.MarkPersistentFlagDirname("directory"); err != nil {
		return fmt.Errorf("failed to mark the \"directory\" flag as a dirname: %w", err)
	}

	// Logging options.
	cmd.PersistentFlags().String("log-file", config.DefaultLogFile, "print logs to the specified file")

	if err := cmd.MarkPersistentFlagFilename("log-file"); err != nil {
		return fmt.Errorf("failed to mark the \"log-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().Bool("log-stderr", false, "print logs to stderr")
	cmd.PersistentFlags().Bool("log-stdout", false, "print logs to stdout")
	cmd.PersistentFlags().Bool("log-none", false, "disables logging")
	cmd.PersistentFlags().Bool("log-null", false, "disables logging")
	cmd.PersistentFlags().Bool("disable-logs", false, "disables logging")
	cmd.PersistentFlags().Bool("no-logs", false, "disables logging")
	cmd.MarkFlagsMutuallyExclusive("log-file", "log-stderr", "log-stdout", "log-null", "disable-logs", "no-logs")

	if err := cmd.PersistentFlags().MarkHidden("log-none"); err != nil {
		return fmt.Errorf("failed to mark the \"log-none\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("log-null"); err != nil {
		return fmt.Errorf("failed to mark the \"log-null\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("disable-logs"); err != nil {
		return fmt.Errorf("failed to mark the \"disable-logs\" flag as hidden: %w", err)
	}

	cmd.PersistentFlags().String(
		"log-level",
		config.DefaultLogLevel,
		"logging level to use, possible values are: debug, info, warn (or warning), error (or err), and off",
	)
	cmd.PersistentFlags().String(
		"log-format",
		config.DefaultLogFormat,
		fmt.Sprintf(
			"format for the logs, possible values are: %q and %q",
			config.ValueLogFormatJSON,
			config.ValueLogFormatText,
		),
	)

	cmd.PersistentFlags().Bool("no-log-rotation", !config.DefaultRotateLogs, "disable the built-in log rotation")
	cmd.PersistentFlags().Bool("disable-log-rotation", !config.DefaultRotateLogs, "disable the built-in log rotation")
	cmd.MarkFlagsMutuallyExclusive("no-log-rotation", "disable-log-rotation")

	if err := cmd.PersistentFlags().MarkHidden("disable-log-rotation"); err != nil {
		return fmt.Errorf("failed to mark the \"disable-log-rotation\" flag as hidden: %w", err)
	}

	return nil
}

func runHelp(cmd *cobra.Command, _ []string) error {
	if err := cmd.Help(); err != nil {
		return fmt.Errorf("failed to run the help command: %w", err)
	}

	return nil
}

func persistentPreRun(cmd *cobra.Command, _ []string) error {
	vpr, ok := cmd.Context().Value(config.ViperContextKey).(*viper.Viper)
	if !ok || vpr == nil {
		panic(fmt.Sprintf("%v", config.ErrNoViper))
	}

	if _, err := initRootConfig(vpr, cmd); err != nil {
		panic(fmt.Sprintf("failed to initialize the config: %v", err))
	}

	slog.Info("Starting a new Reginald run", "command", cmd.Name())

	if configFileFound(vpr) {
		slog.Info("Config file read", "path", vpr.ConfigFileUsed())
	} else {
		slog.Warn("Config file not found")
	}

	slog.Info("Running with the following settings", slog.Any("config", vpr.AllSettings()))

	return nil
}
