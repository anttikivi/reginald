package command

import (
	"fmt"
	"log/slog"

	"github.com/anttikivi/reginald/internal/command/bootstrap"
	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// New creates a new instance of the root command which includes the
// subcommands.
// TODO: Thinking that maybe the context should be passed in here.
func New(cfg *viper.Viper, ver string) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:               constants.CommandName + " command [flags]",
		Short:             constants.Name + " is the workstation valet",
		Long:              strutil.Cap(description(), constants.HelpLineLen),
		Version:           ver,
		PersistentPreRunE: persistentPreRun,
		RunE:              runHelp,
	}

	cmd.SetVersionTemplate(version.Template(ver))

	if err := addFlags(cmd); err != nil {
		return nil, fmt.Errorf("%w", err)
	}

	if err := cfg.BindPFlag("color", cmd.PersistentFlags().Lookup("color")); err != nil {
		return nil, fmt.Errorf("failed to bind the flag \"color\" to config: %w", err)
	}

	cmd.AddCommand(bootstrap.NewCommand())
	cmd.AddCommand(version.NewCommand(ver))

	return cmd, nil
}

// New creates a new instance of the root command for generating the documentation.
func NewDoc(ver string) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:     constants.CommandName + " [-v | --version] [-h | --help] [--color | --no-color] [-c <path> | --config-file <path>] [-C <path> | --directory <path>] [--log-file <path> | --log-stderr | --log-stdout | --no-logs] [--log-level] [--log-format <\"json\" | \"text\">] [--no-log-rotation] <command> [<args>]", //nolint:lll // can't really make this shorter
		Short:   "the workstation valet",
		Long:    description(),
		Version: ver,
	}

	if err := addFlags(cmd); err != nil {
		return nil, fmt.Errorf("%w", err)
	}

	cmd.AddCommand(bootstrap.NewDocCommand())
	cmd.AddCommand(version.NewDocCommand(ver))

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

	cmd.PersistentFlags().StringP("directory", "C", "", "path to the local dotfiles directory")

	if err := cmd.MarkPersistentFlagDirname("directory"); err != nil {
		return fmt.Errorf("failed to mark the \"directory\" flag as a dirname: %w", err)
	}

	// Logging options.
	cmd.PersistentFlags().String("log-file", defaultLogFile(), "print logs to the specified file")

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
		"info",
		"logging level to use, possible values are: debug, info, warn (or warning), error (or err), and off",
	)
	cmd.PersistentFlags().String(
		"log-format",
		defaultLogFormat,
		"format for the logs, possible values are: json and text",
	)

	cmd.PersistentFlags().Bool("no-log-rotation", !rotateLogsDefault, "disable the built-in log rotation")
	cmd.PersistentFlags().Bool("disable-log-rotation", !rotateLogsDefault, "disable the built-in log rotation")
	cmd.MarkFlagsMutuallyExclusive("no-log-rotation", "disable-log-rotation")

	if err := cmd.PersistentFlags().MarkHidden("disable-log-rotation"); err != nil {
		return fmt.Errorf("failed to mark the \"disable-log-rotation\" flag as hidden: %w", err)
	}

	return nil
}

func description() string {
	return constants.Name + ` is the workstation valet for managing your workstation configuration and installed tools.`
}

func runHelp(cmd *cobra.Command, _ []string) error {
	if err := cmd.Help(); err != nil {
		return fmt.Errorf("failed to run the help command: %w", err)
	}

	return nil
}

func persistentPreRun(cmd *cobra.Command, _ []string) error {
	cfg, ok := cmd.Context().Value(constants.ConfigContextKey).(*viper.Viper)
	if !ok || cfg == nil {
		return fmt.Errorf("%w", ErrNoConfig)
	}

	if err := initConfig(cfg, cmd); err != nil {
		return fmt.Errorf("failed to initialize the config: %w", err)
	}

	slog.Info("Starting a new Reginald run", "command", cmd.Name())
	slog.Info("Logging initialized", "rotate-logs", cfg.GetBool("rotate-logs"))

	if configFileFound(cfg) {
		slog.Info("Config file read", "config-file", cfg.ConfigFileUsed())
	} else {
		slog.Warn("Config file not found")
	}

	slog.Info("Running with the following settings", slog.Any("config", cfg.AllSettings()))

	return nil
}
