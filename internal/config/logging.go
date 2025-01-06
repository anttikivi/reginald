package config

import (
	"errors"
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	errInvalidLogOutVar    = errors.New("invalid log output variable")
	errInvalidLogOutValue  = errors.New("invalid log output value")
	errMultipleNoneAliases = errors.New("multiple aliases for `log.none` used")
)

func handleLogOutConfigValue(vpr *viper.Viper, varname, output string) (string, string, error) {
	if s := vpr.GetString(varname); slices.Contains(logging.AllOutputValues, s) {
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

func handleLogFileConfigValue(vpr *viper.Viper, varname, output, filename string) (string, string) {
	if s := vpr.GetString(varname); s != "" {
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

func handleStderroutConfigValue(vpr *viper.Viper, varname, output string) string {
	if b := vpr.GetBool(varname); b {
		return strings.TrimPrefix(varname, "log.")
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

	output, filename := "", ""
	noneAliasUsed := ""

	// Ensure that no duplicate keys are specified.
	// The order of the keys are as specified in the variable.
	for _, name := range logging.AllOutputKeys {
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
		case logging.KeyStderr, logging.KeyStdout:
			output = handleStderroutConfigValue(vpr, name, output)
		case logging.KeyNone, logging.KeyNil, logging.KeyNull, logging.KeyDisable, logging.KeyDisabled:
			if b := vpr.GetBool(name); b {
				if noneAliasUsed == "" {
					noneAliasUsed = name
					output = strings.TrimPrefix(name, "log.")
				} else {
					return "", "", fmt.Errorf("%w: %q and %q", errMultipleNoneAliases, noneAliasUsed, name)
				}
			}
		default:
			panic(exit.New(exit.CommandInitFailure, fmt.Errorf("%w: %s", errInvalidLogOutVar, name)))
		}
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
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"log-file\" flag: %w", err),
				),
			)
		}

		vpr.Set(logging.KeyFile, f)
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err),
				),
			)
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputStderr)
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err),
				),
			)
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputStdout)
		}
	case cmd.Flags().Changed("log-none"):
		v, err := cmd.Flags().GetBool("log-none")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"log-none\" flag: %w", err),
				),
			)
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err),
				),
			)
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err),
				),
			)
		}

		if v {
			vpr.Set(logging.KeyOutput, logging.ValueOutputNone)
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err),
				),
			)
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
	for _, alias := range logging.AllOutputKeys {
		if err := vpr.BindEnv(alias); err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf(
						"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
						EnvReplacer.Replace(strings.ToUpper(alias)),
						err,
					),
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

	output := vpr.GetString(logging.KeyOutput)
	switch output {
	case logging.ValueOutputFile:
		vpr.SetDefault(logging.KeyFormat, logging.ValueFormatJSON)
	case logging.ValueOutputStderr, logging.ValueOutputStdout:
		vpr.SetDefault(logging.KeyFormat, logging.ValueFormatText)
	default:
		vpr.SetDefault(logging.KeyFormat, logging.ValueFormatJSON)
	}

	return nil
}
