package command

import (
	"errors"
	"fmt"
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

const (
	defaultLogFormat  = "json"
	defaultLogLevel   = "info"
	rotateLogsDefault = true
)

func defaultLogFile() string {
	return strings.ToLower(constants.Name) + ".log"
}

func configFileFound() bool {
	return viper.ConfigFileUsed() != ""
}

func setDefaults() {
	viper.SetDefault("color", !color.NoColor)
	viper.SetDefault("log-destination", "file")
	viper.SetDefault("log-file", defaultLogFile())
	viper.SetDefault("log-format", defaultLogFormat)
	viper.SetDefault("log-level", defaultLogLevel)
	viper.SetDefault("rotate-logs", rotateLogsDefault)
}

// bindPersistentString binds a Viper config value to a persistent flag string
// if that string has been set by the user with a command-line argument.
// This additional check is needed because the command-line arguments always
// have a default value, usually an empty string, that would otherwise override
// the Viper default or values from other sources.
// This function also binds the values to the environment variables so that the
// values are included in all settings if the environment variables are set.
func bindPersistentString(cmd *cobra.Command, n string) error {
	if cmd.Flags().Changed(n) {
		if err := viper.BindPFlag(n, cmd.PersistentFlags().Lookup(n)); err != nil {
			return fmt.Errorf("failed to bind the flag \"%s\" to config: %w", n, err)
		}
	}

	if err := viper.BindEnv(n); err != nil {
		return fmt.Errorf(
			"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
			strings.ReplaceAll(strings.ToUpper(n), "-", "_"),
			err,
		)
	}

	return nil
}

// readConfig is a utility that reads the config file with Viper.
// The necessary steps for finding the config should be done before calling this
// function.
// The function returns true if the config file was read, otherwise false.
// If the config file is found but could not be read, the function returns false
// and an error.
func readConfig() (bool, error) {
	if err := viper.ReadInConfig(); err != nil {
		var notFoundError viper.ConfigFileNotFoundError
		if !errors.As(err, &notFoundError) {
			return false, fmt.Errorf("could not read the configuration file: %w", err)
		}

		return false, nil
	}

	return true, nil
}

// resolveConfigFile looks up the different locations for the config file and
// reads the first that matches.
// The first return value is a boolean telling whether a file was found and
// read.
func resolveConfigFile() (bool, error) {
	// Reginald is flexible about the configuration file to use. You can
	// use multiple types of configuration files so the extensions are
	// omitted from the following examples.
	var (
		configFound = false
		err         error
	)

	// Before looking up the config file in the specified locations, see
	// if the command-line flag or the environment variable is set.
	configFile := viper.GetString("config-file")
	if configFile != "" {
		viper.SetConfigFile(configFile)

		configFound, err = readConfig()
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// First the config is looked for in the current working directory.
	// Files that match: ./reginald
	if !configFound {
		viper.SetConfigName("reginald")
		viper.AddConfigPath(".")

		configFound, err = readConfig()
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Next the current working directory but with dot in from of the
	// file. Files that match: ./.reginald
	if !configFound {
		viper.SetConfigName(".reginald")
		viper.AddConfigPath(".")

		configFound, err = readConfig()
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Next the XDG_CONFIG_HOME/reginald, defaulting to
	// ~/.config/reginald.
	// TODO: Look for config files in a directory named `reginald` in
	// XDG_CONFIG_HOME.
	if !configFound {
		viper.SetConfigName("reginald")
		viper.AddConfigPath("${XDG_CONFIG_HOME}")
		viper.AddConfigPath("${HOME}/.config")

		configFound, err = readConfig()
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Next the user's home directory. If for some reason the user wants
	// to include the config file there without prefixing the filename
	// with a dot, we'll look for that first.
	if !configFound {
		viper.SetConfigName("reginald")
		viper.AddConfigPath("${HOME}")

		configFound, err = readConfig()
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Finally the home directory but with a dot in the front.
	if !configFound {
		viper.SetConfigName(".reginald")
		viper.AddConfigPath("${HOME}")

		configFound, err = readConfig()
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	return configFound, nil
}

// initConfig initializes the configuration for the current run.
func initConfig(cmd *cobra.Command) error {
	setDefaults()

	noColor, err := cmd.Flags().GetBool("no-color")
	if err != nil {
		return fmt.Errorf("failed to get the value for the \"no-color\" flag: %w", err)
	}

	if noColor {
		viper.Set("color", false)
	}

	if err := bindPersistentString(cmd, "config-file"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cmd, "directory"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cmd, "log-file"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cmd, "log-format"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cmd, "log-level"); err != nil {
		return fmt.Errorf("%w", err)
	}

	// Check the log rotation.
	// There are two command-line flags that can be used to disable rotating
	// log; check if either of them have been changed and set the `rotate-logs`
	// config value to false if so.
	// Command-line flags take precedence over other sources so using the manual
	// `Set` is also safe.
	if cmd.Flags().Changed("no-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("no-log-rotation")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"no-log-rotation\" flag: %w", err)
		}

		if noLogRotation {
			viper.Set("rotate-logs", false)
		}
	}

	if cmd.Flags().Changed("disable-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("disable-log-rotation")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-log-rotation\" flag: %w", err)
		}

		if noLogRotation {
			viper.Set("rotate-logs", false)
		}
	}

	// viper.SetEnvPrefix(constants.CommandName)
	viper.SetEnvPrefix(strings.ToLower(constants.Name))
	viper.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
	viper.AutomaticEnv()

	if !viper.GetBool("color") {
		color.NoColor = true
	}

	if _, err := resolveConfigFile(); err != nil {
		return fmt.Errorf("failed to resolve the config file: %w", err)
	}

	if err := initLogging(cmd); err != nil {
		return fmt.Errorf("failed to init logging: %w", err)
	}

	return nil
}
