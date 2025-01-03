package command

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"strings"

	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/constants/config"
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
	allLogConfigNames = append([]string{config.LogDestinationKey}, logAliases...)
	//nolint:gochecknoglobals // needed across the functions
	logDestValues = append(
		[]string{
			config.LogDestinationValueFile,
			config.LogDestinationValueStderr,
			config.LogDestinationValueStdout,
			config.LogDestinationValueNone,
		},
		config.LogDestinationValueNoneAliases...,
	)
	//nolint:gochecknoglobals // needed across the functions
	logDestNormalValues = []string{
		config.LogDestinationValueFile,
		config.LogDestinationValueStderr, config.LogDestinationValueStdout,
		config.LogDestinationValueNone,
	}
)

var (
	errLogDestUnexpected   = errors.New("unexpected error while parsing log destination")
	errMultipleLogDestSrcs = errors.New("multiple log destinations specified")
	errInvalidLogDestValue = errors.New("invalid log destination value")
	errInvalidLogDestVar   = errors.New("invalid log destination variable")
)

// normalizeLogDestination checks the given value for `log-destination` and
// normalizes it.
// The configuration allows for a more wider range or values, and this function
// does the normalizing.
func normalizeLogDestination(v string) (string, error) {
	s := v
	if s == "disable" || s == "disabled" || s == "nil" || s == "null" || s == "/dev/null" {
		s = config.LogDestinationValueNone
	}

	if s != "" && !slices.Contains(logDestNormalValues, s) {
		return "", fmt.Errorf("%w: %s", errInvalidLogDestValue, s)
	}

	return s, nil
}

func handleLogDestConfigValue(cfg *viper.Viper, n, dest string) (string, string, error) {
	if dest != "" {
		return "", "", fmt.Errorf(
			"%w: the variable %q already contains a value: %q",
			errLogDestUnexpected,
			"dest",
			dest,
		)
	}

	if s := cfg.GetString(n); slices.Contains(logDestValues, s) {
		// The value for `log-destination` is within the valid values
		// and, thus, should be considered.
		return s, "", nil
	} else if s != "" {
		// If we assume the log destination to be a file, require that the value
		// contains a path separator.
		if !strings.ContainsRune(s, os.PathSeparator) {
			return "", "", fmt.Errorf("%w: %q", errInvalidLogDestValue, s)
		}

		// If the value is not a preset value, we assume it to be
		// filename.
		return config.LogDestinationValueFile, s, nil
	}

	return dest, "", nil
}

func handleLogFileConfigValue(cfg *viper.Viper, n, dest, filename string) (string, string) {
	if s := cfg.GetString(n); s != "" {
		if dest == "" {
			return config.LogDestinationValueFile, s
		}

		// If the destination is already set, we can only set the filename.
		// This way we can allow keeping the config for a custom filename
		// while letting the user to change the destination temporarily to
		// something else.
		return dest, s
	}

	return dest, filename
}

func handleStderroutConfigValue(cfg *viper.Viper, n, dest string) string {
	if b := cfg.GetBool(n); b {
		return strings.TrimPrefix(n, "log-")
	}

	return dest
}

// logDestFromConfigs gets the log destination from the config sources prior to
// parsing the command-line flags, i.e. config files and environment variables.
// It also returns the found file name if the logs are set to a file and a name
// is found while going through the config options here.
// If multiple values are found, the last one is overridden.
// The values are checked in the following order:
// log-destination -> log-file -> log-stderr -> log-stdout -> no-logs.
// If a config value has synonyms, like no-logs, only one of those is permitted.
func logDestFromConfigs(cfg *viper.Viper) (string, string, error) {
	var err error

	varName, dest, filename := "", "", ""

	// Ensure that no duplicate keys are specified.
	// The order of the keys are as specified in the variable.
	for _, name := range allLogConfigNames {
		if !cfg.IsSet(name) {
			continue
		}
		// Check that the value is actually set. We don't want to throw
		// error for empty values.
		switch name {
		case config.LogDestinationKey:
			dest, filename, err = handleLogDestConfigValue(cfg, name, dest)
			if err != nil {
				return "", "", fmt.Errorf("%w", err)
			}
		case "log-file":
			dest, filename = handleLogFileConfigValue(cfg, name, dest, filename)
		case "log-stderr", "log-stdout":
			dest = handleStderroutConfigValue(cfg, name, dest)
		case "log-none", "log-null", "disable-logs", "no-logs":
			if b := cfg.GetBool(name); b {
				switch {
				case varName == "":
					varName = name
					dest = config.LogDestinationValueNone
				case dest == config.LogDestinationValueNone:
					return "", "", fmt.Errorf(
						"%w: both %q and %q used to set log destination",
						errMultipleLogDestSrcs,
						varName,
						name,
					)
				default:
					return "", "", fmt.Errorf(
						"%w: both %q and %q enabled as log destination",
						errMultipleLogDestSrcs,
						dest,
						name,
					)
				}
			}
		default:
			return "", "", fmt.Errorf("%w: %s", errInvalidLogDestVar, name)
		}
	}

	dest, err = normalizeLogDestination(dest)
	if err != nil {
		return "", "", fmt.Errorf("failed to normalize the log destination: %w", err)
	}

	return dest, filename, nil
}

// parseLogDestinationConfigs parses the log destination from the Viper sources
// apart from command-line flags. It returns an error if more than one
// destination value is specified.
func parseLogDestinationConfigs(cfg *viper.Viper) error {
	dest, filename, err := logDestFromConfigs(cfg)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if dest != "" {
		cfg.Set(config.LogDestinationKey, dest)
	}

	if filename != "" {
		cfg.Set(config.LogFileKey, filename)
	}

	return nil
}

// parseLogDestFlags parses the log destination flags, overriding the values
// from other sources.
// TODO: See if this functions complexity can be reduced.
//
//nolint:cyclop // this function does what it needs to
func parseLogDestFlags(cfg *viper.Viper, cmd *cobra.Command) error {
	// Check the different command-line arguments and see if they are set. As
	// command-line options override options from other sources, set the values
	// according to them if they are set. Otherwise the other sources are used.
	// The flags are already marked as mutually exclusive so we can safely
	// ignore the case that multiple values are selected.
	switch {
	case cmd.Flags().Changed("log-file"):
		cfg.Set(config.LogDestinationKey, config.LogDestinationValueFile)

		f, err := cmd.Flags().GetString("log-file")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-file\" flag: %w", err)
		}

		cfg.Set(config.LogFileKey, f)
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err)
		}

		if v {
			cfg.Set(config.LogDestinationKey, "stderr")
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err)
		}

		if v {
			cfg.Set(config.LogDestinationKey, "stdout")
		}
	case cmd.Flags().Changed("log-none"):
		v, err := cmd.Flags().GetBool("log-none")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-none\" flag: %w", err)
		}

		if v {
			cfg.Set(config.LogDestinationKey, config.LogDestinationValueNone)
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err)
		}

		if v {
			cfg.Set(config.LogDestinationKey, config.LogDestinationValueNone)
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err)
		}

		if v {
			cfg.Set(config.LogDestinationKey, config.LogDestinationValueNone)
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err)
		}

		if v {
			cfg.Set(config.LogDestinationKey, config.LogDestinationValueNone)
		}
	}

	return nil
}

// setLogDestination checks the different possible flags and environment
// variables that can be set for `log-destination` and sets the
// `log-destination` config value correctly.
func setLogDestination(cfg *viper.Viper, cmd *cobra.Command) error {
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

	if err := parseLogDestinationConfigs(cfg); err != nil {
		return fmt.Errorf("failed to parse the log destination: %w", err)
	}

	if err := parseLogDestFlags(cfg, cmd); err != nil {
		return fmt.Errorf("failed to parse the log destination: %w", err)
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

	if err := setLogDestination(cfg, cmd); err != nil {
		return fmt.Errorf("failed to set the log destination: %w", err)
	}

	// Set the default log destination and file if they are not set.
	if !cfg.IsSet(config.LogDestinationKey) {
		cfg.Set(config.LogDestinationKey, config.LogDestinationValueFile)
	}

	if !cfg.IsSet(config.LogFileKey) {
		cfg.Set(config.LogFileKey, defaultLogFile())
	}

	logfmt := cfg.GetString("log-format")
	if logfmt == "" {
		dest := cfg.GetString(config.LogDestinationKey)
		switch dest {
		case config.LogDestinationValueFile:
			cfg.Set("log-format", "json")
		case "stderr", "stdout":
			cfg.Set("log-format", "text")
		default:
			cfg.Set("log-format", "json")
		}
	}

	// If the log level is set to `off`, the destination for log is overridden
	// and logs will be disabled.
	levelName := cfg.GetString("log-level")
	if levelName == "off" {
		cfg.Set(config.LogDestinationKey, config.LogDestinationValueNone)
	}

	logLevel, err := logging.Level(levelName)
	if err != nil {
		return fmt.Errorf("failed to get the log level: %w", err)
	}

	// Create the correct writer for the logs.
	logWriter, err := logging.Writer(
		cfg.GetString(config.LogDestinationKey),
		cfg.GetString(config.LogFileKey),
		cfg.GetBool("rotate-logs"),
	)
	if err != nil {
		return fmt.Errorf("failed to get the log writer: %w", err)
	}

	logHandler, err := logging.Handler(logWriter, cfg.GetString("log-format"), logLevel)
	if err != nil {
		return fmt.Errorf("failed to create the log handler: %w", err)
	}

	logger := slog.New(logHandler)

	slog.SetDefault(logger)

	return nil
}
