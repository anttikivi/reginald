package config

import (
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	//nolint:gochecknoglobals // needed across the functions
	logAliases = []string{
		"log.file",
		"log.stderr",
		"log.stdout",
		"log.none",
		"log.null",
		"log.disable",
	}
	//nolint:gochecknoglobals // needed across the functions
	allLogConfigNames = append([]string{logging.KeyOutput}, logAliases...)
	//nolint:gochecknoglobals // needed across the functions
	logOutValues = append(
		[]string{
			logging.ValueOutputFile,
			logging.ValueOutputStderr,
			logging.ValueOutputStdout,
			logging.ValueOutputNone,
		},
		logging.OutputValueNoneAliases...,
	)
	//nolint:gochecknoglobals // needed across the functions
	logOutNormalValues = []string{
		logging.ValueOutputFile,
		logging.ValueOutputStderr,
		logging.ValueOutputStdout,
		logging.ValueOutputNone,
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
		s = logging.ValueOutputNone
	}

	if s != "" && !slices.Contains(logOutNormalValues, s) {
		return "", fmt.Errorf("%w: %s", errInvalidLogOutValue, s)
	}

	return s, nil
}

func handleLogOutConfigValue(vpr *viper.Viper, n, output string) (string, string, error) {
	if output != "" {
		return "", "", fmt.Errorf(
			"%w: the variable %q already contains a value: %q",
			errLogOutUnexpected,
			"output",
			output,
		)
	}

	if s := vpr.GetString(n); slices.Contains(logOutValues, s) {
		// The value for `log-output` is within the valid values and, thus,
		// should be considered.
		return s, "", nil
	} else if s != "" {
		// If we assume the log output to be a file, require that the value
		// contains a path separator.
		if !strings.ContainsFunc(s, func(r rune) bool { return r == os.PathSeparator || r == '/' }) {
			return "", "", fmt.Errorf("%w: %q", errInvalidLogOutValue, s)
		}

		// If the value is not a preset value, we assume it to be
		// filename.
		return logging.ValueOutputFile, s, nil
	}

	return output, "", nil
}

func handleLogFileConfigValue(vpr *viper.Viper, n, output, filename string) (string, string) {
	if s := vpr.GetString(n); s != "" {
		if output == "" {
			return logging.ValueOutputFile, s
		}

		// If the output is already set, we can only set the filename. This way
		// we can allow keeping the config for a custom filename while letting
		// the user to change the output temporarily to something else.
		return output, s
	}

	return output, filename
}

func handleStderroutConfigValue(vpr *viper.Viper, n, output string) string {
	if b := vpr.GetBool(n); b {
		return strings.TrimPrefix(n, "log.")
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
func logOutFromConfigs(vpr *viper.Viper) (string, string, error) {
	var err error

	varName, output, filename := "", "", ""

	// Ensure that no duplicate keys are specified.
	// The order of the keys are as specified in the variable.
	for _, name := range allLogConfigNames {
		if !vpr.IsSet(name) {
			continue
		}
		// Check that the value is actually set. We don't want to throw
		// error for empty values.
		switch name {
		case logging.KeyOutput:
			output, filename, err = handleLogOutConfigValue(vpr, name, output)
			if err != nil {
				return "", "", fmt.Errorf("%w", err)
			}
		case logging.KeyFile:
			output, filename = handleLogFileConfigValue(vpr, name, output, filename)
		case "log.stderr", "log.stdout":
			output = handleStderroutConfigValue(vpr, name, output)
		case "log.none", "log.null", "log.disable":
			if b := vpr.GetBool(name); b {
				switch {
				case varName == "":
					varName = name
					output = logging.ValueOutputNone
				case output == logging.ValueOutputNone:
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
func parseLogOutputConfigs(vpr *viper.Viper) error {
	output, filename, err := logOutFromConfigs(vpr)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if output != "" {
		vpr.Set(logging.KeyOutput, output)
	}

	if filename != "" {
		vpr.Set(logging.KeyFile, filename)
	}

	return nil
}

// parseLogOutFlags parses the log output flags, overriding the values from
// other sources.
// TODO: See if this functions complexity can be reduced.
//
//nolint:cyclop // this function does what it needs to
func parseLogOutFlags(vpr *viper.Viper, cmd *cobra.Command) {
	// Check the different command-line arguments and see if they are set. As
	// command-line options override options from other sources, set the values
	// according to them if they are set. Otherwise the other sources are used.
	// The flags are already marked as mutually exclusive so we can safely
	// ignore the case that multiple values are selected.
	switch {
	case cmd.Flags().Changed("log-file"):
		vpr.Set(logging.KeyOutput, logging.ValueOutputFile)

		f, err := cmd.Flags().GetString("log-file")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"log-file\" flag: %w", err))
		}

		vpr.Set(logging.KeyFile, f)
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err))
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputStderr)
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err))
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputStdout)
		}
	case cmd.Flags().Changed("log-none"):
		v, err := cmd.Flags().GetBool("log-none")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"log-none\" flag: %w", err))
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err))
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err))
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			panic(fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err))
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	}
}

// setLogOutput checks the different possible flags and environment variables
// that can be set for `log-output` and sets the `log-output` config value
// correctly.
func setLogOutput(vpr *viper.Viper, cmd *cobra.Command) error {
	// Bind all of these to environment variables. Later we check for the
	// command-line flags and as those override all of the other options.
	for _, alias := range allLogConfigNames {
		if err := vpr.BindEnv(alias); err != nil {
			panic(
				fmt.Sprintf(
					"failed to bind the environment variable \"REGINALD_%s\" to config: %v",
					EnvReplacer.Replace(strings.ToUpper(alias)),
					err,
				),
			)
		}
	}

	if err := parseLogOutputConfigs(vpr); err != nil {
		return fmt.Errorf("failed to parse the log output: %w", err)
	}

	parseLogOutFlags(vpr, cmd)

	return nil
}

func parseLoggingConfig(vpr *viper.Viper, cmd *cobra.Command) error {
	if err := setLogOutput(vpr, cmd); err != nil {
		return fmt.Errorf("%w", err)
	}

	logfmt := vpr.GetString(logging.KeyFormat)
	if logfmt == "" {
		output := vpr.GetString(logging.KeyOutput)
		switch output {
		case logging.ValueOutputFile:
			vpr.SetDefault(logging.KeyFormat, logging.ValueFormatJSON)
		case logging.ValueOutputStderr, logging.ValueOutputStdout:
			vpr.SetDefault(logging.KeyFormat, logging.ValueFormatText)
		default:
			vpr.SetDefault(logging.KeyFormat, logging.ValueFormatJSON)
		}
	}

	// If the log level is set to `off`, the output for log is overridden and
	// logs will be disabled.
	levelName := vpr.GetString(logging.KeyLevel)
	if levelName == "off" {
		vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
	}

	return nil
}
