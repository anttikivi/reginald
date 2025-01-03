package command

import (
	"errors"
	"fmt"
	"path/filepath"
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

var ErrNoConfig = errors.New("no config instance in context")

func NewConfig() *viper.Viper {
	return viper.New()
}

func defaultLogFile() string {
	return strings.ToLower(constants.Name) + ".log"
}

func configFileFound(cfg *viper.Viper) bool {
	return cfg.ConfigFileUsed() != ""
}

func setDefaults(cfg *viper.Viper) {
	cfg.SetDefault("color", !color.NoColor)
	cfg.SetDefault("log-level", defaultLogLevel)
	cfg.SetDefault("rotate-logs", rotateLogsDefault)
}

// bindPersistentString binds a Viper config value to a persistent flag string
// if that string has been set by the user with a command-line argument.
// This additional check is needed because the command-line arguments always
// have a default value, usually an empty string, that would otherwise override
// the Viper default or values from other sources.
// This function also binds the values to the environment variables so that the
// values are included in all settings if the environment variables are set.
func bindPersistentString(cfg *viper.Viper, cmd *cobra.Command, n string) error {
	if cmd.Flags().Changed(n) {
		if err := cfg.BindPFlag(n, cmd.PersistentFlags().Lookup(n)); err != nil {
			return fmt.Errorf("failed to bind the flag \"%s\" to config: %w", n, err)
		}
	}

	if err := cfg.BindEnv(n); err != nil {
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
func readConfig(cfg *viper.Viper) (bool, error) {
	if err := cfg.ReadInConfig(); err != nil {
		var notFoundError viper.ConfigFileNotFoundError
		if !errors.As(err, &notFoundError) {
			return false, fmt.Errorf("could not read the configuration file: %w", err)
		}

		return false, nil
	}

	return true, nil
}

func tryConfigDir(cfg *viper.Viper, dir string, names []string) (bool, error) {
	var (
		found = false
		err   error
	)

	cfg.AddConfigPath(dir)

	for _, s := range names {
		if !found {
			cfg.SetConfigName(s)

			found, err = readConfig(cfg)
			if err != nil {
				return found, fmt.Errorf("%w", err)
			}
		}
	}

	return found, nil
}

// resolveConfigFile looks up the different locations for the config file and
// reads the first that matches.
// The first return value is a boolean telling whether a file was found and
// read.
func resolveConfigFile(cfg *viper.Viper) (bool, error) {
	// Reginald is flexible about the configuration file to use. You can
	// use multiple types of configuration files so the extensions are
	// omitted from the following examples.
	var (
		configFound = false
		configNames = []string{
			strings.ToLower(constants.Name),
			strings.ToLower(constants.CommandName),
			"." + strings.ToLower(constants.Name),
			"." + strings.ToLower(constants.CommandName),
		}
		err error
	)

	// Before looking up the config file in the specified locations, see
	// if the command-line flag or the environment variable is set.
	configFile := cfg.GetString("config-file")
	if configFile != "" {
		cfg.SetConfigFile(configFile)

		configFound, err = readConfig(cfg)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Look up the directory specified with `--directory`.
	if !configFound && cfg.GetString("directory") != "" {
		configFound, err = tryConfigDir(cfg, cfg.GetString("directory"), configNames)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Current working directory.
	if !configFound {
		configFound, err = tryConfigDir(cfg, ".", configNames)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $XDG_CONFIG_HOME/reginald, filename must be config.
	if !configFound {
		configFound, err = tryConfigDir(
			cfg,
			filepath.Join("${XDG_CONFIG_HOME}", strings.ToLower(constants.Name)),
			[]string{"config"},
		)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $XDG_CONFIG_HOME, matches files without a dot prefix.
	if !configFound {
		configFound, err = tryConfigDir(cfg, "${XDG_CONFIG_HOME}", configNames[:2])
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $HOME/.config/reginald, filename must be config.
	if !configFound {
		configFound, err = tryConfigDir(
			cfg,
			filepath.Join("$HOME", ".config", strings.ToLower(constants.Name)),
			[]string{"config"},
		)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $HOME/.config, matches files without a dot prefix.
	if !configFound {
		configFound, err = tryConfigDir(cfg, filepath.Join("$HOME", ".config"), configNames[:2])
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Home directory.
	if !configFound {
		configFound, err = tryConfigDir(cfg, "$HOME", configNames)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	return configFound, nil
}

// initConfig initializes the configuration for the current run.
func initConfig(cfg *viper.Viper, cmd *cobra.Command) error {
	setDefaults(cfg)

	noColor, err := cmd.Flags().GetBool("no-color")
	if err != nil {
		return fmt.Errorf("failed to get the value for the \"no-color\" flag: %w", err)
	}

	if noColor {
		cfg.Set("color", false)
	}

	if err := bindPersistentString(cfg, cmd, "config-file"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cfg, cmd, "directory"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cfg, cmd, "log-format"); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := bindPersistentString(cfg, cmd, "log-level"); err != nil {
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
			cfg.Set("rotate-logs", false)
		}
	}

	if cmd.Flags().Changed("disable-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("disable-log-rotation")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-log-rotation\" flag: %w", err)
		}

		if noLogRotation {
			cfg.Set("rotate-logs", false)
		}
	}

	// cfg.SetEnvPrefix(constants.CommandName)
	cfg.SetEnvPrefix(strings.ToLower(constants.Name))
	cfg.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
	cfg.AutomaticEnv()

	if _, err := resolveConfigFile(cfg); err != nil {
		return fmt.Errorf("failed to resolve the config file: %w", err)
	}

	if !cfg.GetBool("color") {
		color.NoColor = true
	}

	if err := initLogging(cfg, cmd); err != nil {
		return fmt.Errorf("failed to init logging: %w", err)
	}

	return nil
}
