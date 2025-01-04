package command

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"strings"

	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	//nolint:gochecknoglobals // needed across the functions
	logAliases = []string{
		"log-file",
		"log-stderr",
		"log-stdout",
		"log-none",
		"log-null",
		"disable-logs",
		"no-logs",
	}
	//nolint:gochecknoglobals // needed across the functions
	allLogConfigNames = append([]string{config.KeyLogOutput}, logAliases...)
	//nolint:gochecknoglobals // needed across the functions
	logOutValues = append(
		[]string{
			config.ValueLogOutputFile,
			config.ValueLogOutputStderr,
			config.ValueLogOutputStdout,
			config.ValueLogOutputNone,
		},
		config.LogOutputValueNoneAliases...,
	)
	//nolint:gochecknoglobals // needed across the functions
	logOutNormalValues = []string{
		config.ValueLogOutputFile,
		config.ValueLogOutputStderr,
		config.ValueLogOutputStdout,
		config.ValueLogOutputNone,
	}
)

var (
	errLogOutUnexpected   = errors.New("unexpected error while parsing log output")
	errMultipleLogOutSrcs = errors.New("multiple log outputs specified")
	errInvalidLogOutValue = errors.New("invalid log output value")
	errInvalidLogOutVar   = errors.New("invalid log output variable")
)

// normalizeLogOutput checks the given value for `log-output` and normalizes it.
// The configuration allows for a more wider range or values, and this function
// does the normalizing.
func normalizeLogOutput(v string) (string, error) {
	s := v
	if s == "disable" || s == "disabled" || s == "nil" || s == "null" || s == "/dev/null" {
		s = config.ValueLogOutputNone
	}

	if s != "" && !slices.Contains(logOutNormalValues, s) {
		return "", fmt.Errorf("%w: %s", errInvalidLogOutValue, s)
	}

	return s, nil
}

func handleLogOutConfigValue(cfg *viper.Viper, n, output string) (string, string, error) {
	if output != "" {
		return "", "", fmt.Errorf(
			"%w: the variable %q already contains a value: %q",
			errLogOutUnexpected,
			"output",
			output,
		)
	}

	if s := cfg.GetString(n); slices.Contains(logOutValues, s) {
		// The value for `log-output` is within the valid values and, thus,
		// should be considered.
		return s, "", nil
	} else if s != "" {
		// If we assume the log output to be a file, require that the value
		// contains a path separator.
		if !strings.ContainsRune(s, os.PathSeparator) {
			return "", "", fmt.Errorf("%w: %q", errInvalidLogOutValue, s)
		}

		// If the value is not a preset value, we assume it to be
		// filename.
		return config.ValueLogOutputFile, s, nil
	}

	return output, "", nil
}

func handleLogFileConfigValue(cfg *viper.Viper, n, output, filename string) (string, string) {
	if s := cfg.GetString(n); s != "" {
		if output == "" {
			return config.ValueLogOutputFile, s
		}

		// If the output is already set, we can only set the filename. This way
		// we can allow keeping the config for a custom filename while letting
		// the user to change the output temporarily to something else.
		return output, s
	}

	return output, filename
}

func handleStderroutConfigValue(cfg *viper.Viper, n, output string) string {
	if b := cfg.GetBool(n); b {
		return strings.TrimPrefix(n, "log-")
	}

	return output
}

// logOutFromConfigs gets the log output from the config sources prior to
// parsing the command-line flags, i.e. config files and environment variables.
// It also returns the found file name if the logs are set to a file and a name
// is found while going through the config options here. If multiple values are
// found, the last one is overridden. The values are checked in the following
// order: log-output -> log-file -> log-stderr -> log-stdout -> no-logs. If a
// config value has synonyms, like no-logs, only one of those is permitted.
func logOutFromConfigs(cfg *viper.Viper) (string, string, error) {
	var err error

	varName, output, filename := "", "", ""

	// Ensure that no duplicate keys are specified.
	// The order of the keys are as specified in the variable.
	for _, name := range allLogConfigNames {
		if !cfg.IsSet(name) {
			continue
		}
		// Check that the value is actually set. We don't want to throw
		// error for empty values.
		switch name {
		case config.KeyLogOutput:
			output, filename, err = handleLogOutConfigValue(cfg, name, output)
			if err != nil {
				return "", "", fmt.Errorf("%w", err)
			}
		case "log-file":
			output, filename = handleLogFileConfigValue(cfg, name, output, filename)
		case "log-stderr", "log-stdout":
			output = handleStderroutConfigValue(cfg, name, output)
		case "log-none", "log-null", "disable-logs", "no-logs":
			if b := cfg.GetBool(name); b {
				switch {
				case varName == "":
					varName = name
					output = config.ValueLogOutputNone
				case output == config.ValueLogOutputNone:
					return "", "", fmt.Errorf(
						"%w: both %q and %q used to set log output",
						errMultipleLogOutSrcs,
						varName,
						name,
					)
				default:
					return "", "", fmt.Errorf(
						"%w: both %q and %q enabled as log output",
						errMultipleLogOutSrcs,
						output,
						name,
					)
				}
			}
		default:
			return "", "", fmt.Errorf("%w: %s", errInvalidLogOutVar, name)
		}
	}

	output, err = normalizeLogOutput(output)
	if err != nil {
		return "", "", fmt.Errorf("failed to normalize the log output: %w", err)
	}

	return output, filename, nil
}

// parseLogOutputConfigs parses the log output from the Viper sources apart from
// command-line flags. It returns an error if more than one output value is
// specified.
func parseLogOutputConfigs(cfg *viper.Viper) error {
	output, filename, err := logOutFromConfigs(cfg)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if output != "" {
		cfg.Set(config.KeyLogOutput, output)
	}

	if filename != "" {
		cfg.Set(config.KeyLogFile, filename)
	}

	return nil
}

// parseLogOutFlags parses the log output flags, overriding the values from
// other sources.
// TODO: See if this functions complexity can be reduced.
//
//nolint:cyclop // this function does what it needs to
func parseLogOutFlags(cfg *viper.Viper, cmd *cobra.Command) error {
	// Check the different command-line arguments and see if they are set. As
	// command-line options override options from other sources, set the values
	// according to them if they are set. Otherwise the other sources are used.
	// The flags are already marked as mutually exclusive so we can safely
	// ignore the case that multiple values are selected.
	switch {
	case cmd.Flags().Changed("log-file"):
		cfg.Set(config.KeyLogOutput, config.ValueLogOutputFile)

		f, err := cmd.Flags().GetString("log-file")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-file\" flag: %w", err)
		}

		cfg.Set(config.KeyLogFile, f)
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err)
		}

		if v {
			cfg.Set(config.KeyLogOutput, "stderr")
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err)
		}

		if v {
			cfg.Set(config.KeyLogOutput, "stdout")
		}
	case cmd.Flags().Changed("log-none"):
		v, err := cmd.Flags().GetBool("log-none")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-none\" flag: %w", err)
		}

		if v {
			cfg.Set(config.KeyLogOutput, config.ValueLogOutputNone)
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err)
		}

		if v {
			cfg.Set(config.KeyLogOutput, config.ValueLogOutputNone)
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err)
		}

		if v {
			cfg.Set(config.KeyLogOutput, config.ValueLogOutputNone)
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err)
		}

		if v {
			cfg.Set(config.KeyLogOutput, config.ValueLogOutputNone)
		}
	}

	return nil
}

// setLogOutput checks the different possible flags and environment variables
// that can be set for `log-output` and sets the `log-output` config value
// correctly.
func setLogOutput(cfg *viper.Viper, cmd *cobra.Command) error {
	// Bind all of these to environment variables. Later we check for the
	// command-line flags and as those override all of the other options.
	for _, alias := range allLogConfigNames {
		if err := cfg.BindEnv(alias); err != nil {
			return fmt.Errorf(
				"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
				strings.ReplaceAll(strings.ToUpper(alias), "-", "_"),
				err,
			)
		}
	}

	if err := parseLogOutputConfigs(cfg); err != nil {
		return fmt.Errorf("failed to parse the log output: %w", err)
	}

	if err := parseLogOutFlags(cfg, cmd); err != nil {
		return fmt.Errorf("failed to parse the log output: %w", err)
	}

	return nil
}

func initLogging(cfg *viper.Viper, cmd *cobra.Command) error {
	// There are some simple commands for displaying basic information.
	// Just disable logging for those.
	if cmd.Name() == version.CmdName {
		logger := slog.New(logging.NullHandler{})
		slog.SetDefault(logger)

		return nil
	}

	if err := setLogOutput(cfg, cmd); err != nil {
		return fmt.Errorf("%w", err)
	}

	logfmt := cfg.GetString(config.KeyLogFormat)
	if logfmt == "" {
		output := cfg.GetString(config.KeyLogOutput)
		switch output {
		case config.ValueLogOutputFile:
			cfg.SetDefault(config.KeyLogFormat, config.ValueLogFormatJSON)
		case "stderr", "stdout":
			cfg.SetDefault(config.KeyLogFormat, config.ValueLogFormatText)
		default:
			cfg.SetDefault(config.KeyLogFormat, config.ValueLogFormatJSON)
		}
	}

	// If the log level is set to `off`, the output for log is overridden and
	// logs will be disabled.
	levelName := cfg.GetString(config.KeyLogLevel)
	if levelName == "off" {
		cfg.Set(config.KeyLogOutput, config.ValueLogOutputNone)
	}

	logLevel, err := logging.Level(levelName)
	if err != nil {
		return fmt.Errorf("failed to get the log level: %w", err)
	}

	// Create the correct writer for the logs.
	logWriter, err := logging.Writer(
		cfg.GetString(config.KeyLogOutput),
		cfg.GetString(config.KeyLogFile),
		cfg.GetBool(config.KeyRotateLogs),
	)
	if err != nil {
		return fmt.Errorf("failed to get the log writer: %w", err)
	}

	logHandler, err := logging.Handler(logWriter, cfg.GetString(config.KeyLogFormat), logLevel)
	if err != nil {
		return fmt.Errorf("failed to create the log handler: %w", err)
	}

	logger := slog.New(logHandler)

	slog.SetDefault(logger)

	slog.Info("Logging initialized", "output", cfg.GetString(config.KeyLogOutput), "format", cfg.GetString(config.KeyLogFormat), "level", cfg.GetString(config.KeyLogLevel), "file", cfg.GetString(config.KeyLogFile), "rotate", cfg.GetBool(config.KeyRotateLogs))

	return nil
}
