package command

import (
	"fmt"
	"log/slog"

	"github.com/anttikivi/reginald/internal/command/bootstrap"
	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/semver"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

func New(ver *semver.Version) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:   constants.CommandName + " command [flags]",
		Short: constants.Name + " is the workstation valet",
		Long: constants.Name + ` is the workstation valet for managing your workstation configuration
and installed tools.
`,
		Version:           ver.String(),
		PersistentPreRunE: persistentPreRun,
		RunE:              runHelp,
	}

	cmd.SetVersionTemplate(version.Template(cmd))

	cmd.PersistentFlags().Bool("color", false, "explicitly enable colors in the command-line output")
	cmd.PersistentFlags().Bool("no-color", false, "disable colors in the command-line output")
	cmd.MarkFlagsMutuallyExclusive("color", "no-color")

	if err := cmd.PersistentFlags().MarkHidden("no-color"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"no-color\" flag as hidden: %w", err)
	}

	if err := viper.BindPFlag("color", cmd.PersistentFlags().Lookup("color")); err != nil {
		return nil, fmt.Errorf("failed to bind the flag \"color\" to config: %w", err)
	}

	cmd.PersistentFlags().StringP("config-file", "c", "", "path to config file")

	if err := cmd.MarkPersistentFlagFilename("config-file", "json", "toml", "yaml", "yml"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"config-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().StringP("directory", "C", "", "path to the local dotfiles directory")

	if err := cmd.MarkPersistentFlagDirname("directory"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"directory\" flag as a dirname: %w", err)
	}

	// Logging options.
	cmd.PersistentFlags().String(
		"log-destination",
		"file",
		"destination for the logs, possible values are: file or filename, stderr, stdout, nil, none, null, and /dev/null",
	)
	cmd.PersistentFlags().Bool("log-stderr", false, "print logs to stderr")
	cmd.PersistentFlags().Bool("log-stdout", false, "print logs to stdout")
	cmd.PersistentFlags().Bool("log-null", false, "disables logging")
	cmd.PersistentFlags().Bool("disable-logs", false, "disables logging")
	cmd.PersistentFlags().Bool("no-logs", false, "disables logging")
	cmd.MarkFlagsMutuallyExclusive("log-destination", "log-stderr", "log-stdout", "log-null", "disable-logs", "no-logs")

	if err := cmd.PersistentFlags().MarkHidden("log-stderr"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-stderr\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("log-stdout"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-stdout\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("log-null"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-null\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("disable-logs"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"disable-logs\" flag as hidden: %w", err)
	}

	cmd.PersistentFlags().String("log-file", defaultLogFile(), "path to the log file, if logs are output to a file")

	if err := cmd.MarkPersistentFlagFilename("log-file"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().String(
		"log-level",
		"info",
		"logging level to use, possible values are: debug, info, warn (or warning), error (or err), and off",
	)
	cmd.PersistentFlags().String("log-format", defaultLogFormat, "format for the logs, possible values are: json and text")

	cmd.PersistentFlags().Bool("no-log-rotation", !rotateLogsDefault, "disable the built-in log rotation")
	cmd.PersistentFlags().Bool("disable-log-rotation", !rotateLogsDefault, "disable the built-in log rotation")
	cmd.MarkFlagsMutuallyExclusive("no-log-rotation", "disable-log-rotation")

	if err := cmd.PersistentFlags().MarkHidden("disable-log-rotation"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"disable-log-rotation\" flag as hidden: %w", err)
	}

	cmd.AddCommand(bootstrap.NewCommand())
	cmd.AddCommand(version.NewCommand(ver))

	return cmd, nil
}

func runHelp(cmd *cobra.Command, _ []string) error {
	if err := cmd.Help(); err != nil {
		return fmt.Errorf("failed to run the help command: %w", err)
	}

	return nil
}

func persistentPreRun(cmd *cobra.Command, _ []string) error {
	if err := initConfig(cmd); err != nil {
		return fmt.Errorf("failed to initialize the config: %w", err)
	}

	slog.Info("Starting a new Reginald run", "command", cmd.Name())
	slog.Info("Logging initialized", "rotate-logs", viper.GetBool("rotate-logs"))

	if configFileFound() {
		slog.Info("Config file read", "config-file", viper.ConfigFileUsed())
	} else {
		slog.Warn("Config file not found")
	}

	slog.Info("Running with the following settings", slog.Any("config", viper.AllSettings()))

	return nil
}
