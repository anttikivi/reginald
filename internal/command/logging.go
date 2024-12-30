package command

import (
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"

	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

const (
	// logDest is the config name for the string that specifies the destination
	// for logs. If it is set to `file`, the `log-file` must also be set.
	logDest = "log-destination"

	// logFile is the config name for the log file path if log destination is
	// set to a file.
	logFile = "log-file"

	// logDestFile is the log destination value when the destination is file.
	logDestFile = "file"

	// logDestNone is the log destination value when logging is disabled.
	logDestNone = "none"
)

var (
	logAliases = []string{ //nolint:gochecknoglobals // needed across the functions
		"log-file",
		"log-stderr",
		"log-stdout",
		"log-none",
		"log-null",
		"disable-logs",
		"no-logs",
	}
	allLogConfigNames = append([]string{logDest}, logAliases...) //nolint:gochecknoglobals // needed across the functions
	logDestValues     = []string{                                //nolint:gochecknoglobals // needed across the functions
		logDestFile,
		"stderr",
		"stdout",
		"disable",
		"nil",
		logDestNone,
		"null",
		"/dev/null",
	}
	logDestNormalValues = []string{ //nolint:gochecknoglobals // needed across the functions
		logDestFile,
		"stderr",
		"stdout",
		logDestNone,
	}
)

var (
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
	if s == "disable" || s == "nil" || s == "null" || s == "/dev/null" {
		s = logDestNone
	}

	if !slices.Contains(logDestNormalValues, s) {
		return "", fmt.Errorf("%w: %s", errInvalidLogDestValue, s)
	}

	return s, nil
}

func handleLogDestConfigValue(n, dest string) (string, string, error) {
	if s := viper.GetString(n); slices.Contains(logDestValues, s) {
		if dest != "" {
			// We probably never end up in here as `log-destination`
			// is first key we check, but let's keep this here for
			// now for the sake of completeness.
			return "", "", fmt.Errorf("%w: both %q and %q enabled as log destination", errMultipleLogDestSrcs, dest, s)
		}

		// The value for `log-destination` is within the valid values
		// and, thus, should be considered.
		return s, "", nil
	} else if s != "" {
		if dest != "" {
			return "", "", fmt.Errorf(
				"%w: both %q and %q (%s) enabled as log destination",
				errMultipleLogDestSrcs,
				dest,
				logDestFile,
				s,
			)
		}

		// If the value is not a preset value, we assume it to be
		// filename.
		return logDestFile, s, nil
	}

	return dest, "", nil
}

func handleLogFileConfigValue(n, dest, filename string) (string, string, error) {
	if s := viper.GetString(n); s != "" {
		switch {
		case dest == "":
			return logDestFile, s, nil
		case filename == "":
			// If the filename is not set yet, we can read it from
			// the config value. The destination should not, however, be changed.
			return dest, s, nil
		default:
			return "", "", fmt.Errorf(
				"%w: both %q and %q (%s) enabled as log destination",
				errMultipleLogDestSrcs,
				dest,
				logDestFile,
				s,
			)
		}
	}

	return dest, filename, nil
}

func handleStderroutConfigValue(n, dest, filename string) (string, error) {
	if b := viper.GetBool(n); b {
		s := strings.TrimPrefix(n, "log-")
		// The destination can be overridden if earlier steps set
		// a filename. For example, out config may have a base case
		// with a log file name but we have chosen to temporarily
		// redirect logging to stderr.
		if dest != "" && (dest != logDestFile || filename == "") {
			return "", fmt.Errorf("%w: both %q and %q enabled as log destination", errMultipleLogDestSrcs, dest, s)
		}

		return s, nil
	}

	return dest, nil
}

// logDestFromConfigs gets the log destination from the config sources prior to
// parsing the command-line flags, i.e. config files and environment variables.
// It also returns the found file name if the logs are set to a file and a name
// is found while going through the config options here.
func logDestFromConfigs() (string, string, error) {
	var err error

	varName, dest, filename := "", "", ""

	// Ensure that no duplicate keys are specified.
	// The order of the keys are as specified in the variable.
	for _, name := range allLogConfigNames {
		if !viper.IsSet(name) {
			continue
		}
		// Check that the value is actually set. We don't want to throw
		// error for empty values.
		switch name {
		case logDest:
			dest, filename, err = handleLogDestConfigValue(name, dest)
			if err != nil {
				return "", "", fmt.Errorf("%w", err)
			}
		case "log-file":
			dest, filename, err = handleLogFileConfigValue(name, dest, filename)
			if err != nil {
				return "", "", fmt.Errorf("%w", err)
			}
		case "log-stderr", "log-stdout":
			dest, err = handleStderroutConfigValue(name, dest, filename)
			if err != nil {
				return "", "", fmt.Errorf("%w", err)
			}
		case "log-none", "log-null", "disable-logs", "no-logs":
			if b := viper.GetBool(name); b {
				// The destination can be overridden if earlier steps set
				// a filename. For example, out config may have a base case
				// with a log file name but we have chosen to temporarily
				// disable logging.
				switch {
				case varName == "" && (dest == "" || (dest == logDestFile && filename != "")):
					varName = name
					dest = logDestNone
				case dest == logDestNone:
					return "", "", fmt.Errorf("%w: both %q and %q used to set log destination", errMultipleLogDestSrcs, varName, name)
				default:
					return "", "", fmt.Errorf("%w: both %q and %q enabled as log destination", errMultipleLogDestSrcs, dest, name)
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
func parseLogDestinationConfigs() error {
	dest, filename, err := logDestFromConfigs()
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if dest != "" {
		viper.Set(logDest, dest)
	}

	if filename != "" {
		viper.Set(logFile, filename)
	}

	return nil
}

// parseLogDestFlags parses the log destination flags, overriding the values
// from other sources.
// TODO: See if this functions complexity can be reduced.
func parseLogDestFlags(cmd *cobra.Command) error { //nolint:cyclop // this function does what it needs to
	// Check the different command-line arguments and see if they are set. As
	// command-line options override options from other sources, set the values
	// according to them if they are set. Otherwise the other sources are used.
	// The flags are already marked as mutually exclusive so we can safely
	// ignore the case that multiple values are selected.
	switch {
	case cmd.Flags().Changed("log-file"):
		viper.Set(logDest, logDestFile)

		f, err := cmd.Flags().GetString("log-file")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-file\" flag: %w", err)
		}

		viper.Set(logFile, f)
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err)
		}

		if v {
			viper.Set(logDest, "stderr")
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err)
		}

		if v {
			viper.Set(logDest, "stdout")
		}
	case cmd.Flags().Changed("log-none"):
		v, err := cmd.Flags().GetBool("log-none")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-none\" flag: %w", err)
		}

		if v {
			viper.Set(logDest, logDestNone)
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err)
		}

		if v {
			viper.Set(logDest, logDestNone)
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err)
		}

		if v {
			viper.Set(logDest, logDestNone)
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err)
		}

		if v {
			viper.Set(logDest, logDestNone)
		}
	}

	return nil
}

// setLogDestination checks the different possible flags and environment
// variables that can be set for `log-destination` and sets the
// `log-destination` config value correctly.
func setLogDestination(cmd *cobra.Command) error {
	// Bind all of these to environment variables. Later we check for the
	// command-line flags and as those override all of the other options.
	for _, alias := range allLogConfigNames {
		if err := viper.BindEnv(alias); err != nil {
			return fmt.Errorf(
				"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
				strings.ReplaceAll(strings.ToUpper(alias), "-", "_"),
				err,
			)
		}
	}

	if err := parseLogDestinationConfigs(); err != nil {
		return fmt.Errorf("failed to parse the log destination: %w", err)
	}

	if err := parseLogDestFlags(cmd); err != nil {
		return fmt.Errorf("failed to parse the log destination: %w", err)
	}

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

	// Set the default log destination and file if they are not set.
	if !viper.IsSet(logDest) {
		viper.Set(logDest, logDestFile)
	}

	if !viper.IsSet(logFile) {
		viper.Set(logFile, defaultLogFile())
	}

	// If the log level is set to `off`, the destination for log is overridden
	// and logs will be disabled.
	levelName := viper.GetString("log-level")
	if levelName == "off" {
		viper.Set(logDest, logDestNone)
	}

	logLevel, err := logging.Level(levelName)
	if err != nil {
		return fmt.Errorf("failed to get the log level: %w", err)
	}

	// Create the correct writer for the logs.
	logWriter, err := logging.Writer(
		viper.GetString(logDest),
		viper.GetString(logFile),
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
