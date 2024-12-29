package command

import (
	"fmt"
	"log/slog"
	"strings"

	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

func parseLogDestination(cmd *cobra.Command) error {
	configName := "log-destination"

	// Check the different command-line arguments and see if they are set. As
	// command-line options override options from other sources, set the values
	// according to them if they are set. Otherwise the other sources are used.
	switch {
	case cmd.Flags().Changed(configName):
		if err := viper.BindPFlag(configName, cmd.PersistentFlags().Lookup(configName)); err != nil {
			return fmt.Errorf("failed to bind the flag \"%s\" to config: %w", configName, err)
		}
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "stderr")
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "stdout")
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "none")
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "none")
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "none")
		}
	}

	return nil
}

// normalizeLogDestination checks the values set for `log-destination`
// normalizes the values that the user can set to it.
func normalizeLogDestination() {
	configName := "log-destination"

	switch v := viper.GetString(configName); v {
	case "stderr", "stdout", "file":
		viper.Set(configName, v)
	case "nil", "none", "null", "/dev/null":
		viper.Set(configName, "none")
	default:
		// For the default case, we assume the user gave a filename.
		viper.Set(configName, "file")
		viper.Set("log-file", v)
	}
}

// setLogDestination checks the different possible flags and environment
// variables that can be set for `log-destination` and sets the
// `log-destination` config value correctly.
func setLogDestination(cmd *cobra.Command) error {
	var (
		configName    = "log-destination"
		configAliases = []string{"log-stderr", "log-stdout", "log-null", "disable-logs", "no-logs"}
	)

	if err := viper.BindEnv(configName); err != nil {
		return fmt.Errorf(
			"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
			strings.ReplaceAll(strings.ToUpper(configName), "-", "_"),
			err,
		)
	}

	for _, alias := range configAliases {
		if err := viper.BindEnv(alias); err != nil {
			return fmt.Errorf(
				"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
				strings.ReplaceAll(strings.ToUpper(alias), "-", "_"),
				err,
			)
		}
	}

	if err := parseLogDestination(cmd); err != nil {
		return fmt.Errorf("failed to parse the log destination: %w", err)
	}

	// Ensure that the value set for the logs destination is correct.
	normalizeLogDestination()

	return nil
}

func initLogging(cmd *cobra.Command) error {
	// There are some simple commands for displaying basic information.
	// Just disable logging for those.
	if cmd.Name() == version.CmdName {
		logger := slog.New(logging.NullHandler{})
		slog.SetDefault(logger)

		return nil
	}

	if err := setLogDestination(cmd); err != nil {
		return fmt.Errorf("failed to set the log destination: %w", err)
	}

	// If the log level is set to `off`, the destination for log is overridden
	// and logs will be disabled.
	levelName := viper.GetString("log-level")
	if levelName == "off" {
		viper.Set("log-destination", "none")
	}

	logLevel, err := logging.Level(levelName)
	if err != nil {
		return fmt.Errorf("failed to get the log level: %w", err)
	}

	// Create the correct writer for the logs.
	logWriter, err := logging.Writer(
		viper.GetString("log-destination"),
		viper.GetString("log-file"),
		viper.GetBool("rotate-logs"),
	)
	if err != nil {
		return fmt.Errorf("failed to get the log writer: %w", err)
	}

	logHandler, err := logging.Handler(logWriter, viper.GetString("log-format"), logLevel)
	if err != nil {
		return fmt.Errorf("failed to create the log handler: %w", err)
	}

	logger := slog.New(logHandler)

	slog.SetDefault(logger)

	return nil
}
