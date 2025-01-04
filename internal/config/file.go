package config

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/spf13/viper"
)

func FileFound(vpr *viper.Viper) bool {
	return vpr.ConfigFileUsed() != ""
}

// readConfig is a utility that reads the config file with Viper.
// The necessary steps for finding the config should be done before calling this
// function.
// The function returns true if the config file was read, otherwise false.
// If the config file is found but could not be read, the function returns false
// and an error.
func readConfig(vpr *viper.Viper) (bool, error) {
	if err := vpr.ReadInConfig(); err != nil {
		var notFoundError viper.ConfigFileNotFoundError
		if !errors.As(err, &notFoundError) {
			return false, fmt.Errorf("could not read the configuration file: %w", err)
		}

		return false, nil
	}

	return true, nil
}

func tryConfigDir(vpr *viper.Viper, dir string, names []string) (bool, error) {
	var (
		found = false
		err   error
	)

	vpr.AddConfigPath(dir)

	for _, s := range names {
		if !found {
			vpr.SetConfigName(s)

			found, err = readConfig(vpr)
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
func resolveConfigFile(vpr *viper.Viper) (bool, error) {
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
	configFile := vpr.GetString(KeyConfigFile)
	if configFile != "" {
		vpr.SetConfigFile(configFile)

		configFound, err = readConfig(vpr)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Look up the directory specified with `--directory`.
	if !configFound && vpr.GetString(KeyDirectory) != "" {
		configFound, err = tryConfigDir(vpr, vpr.GetString(KeyDirectory), configNames)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Current working directory.
	if !configFound {
		configFound, err = tryConfigDir(vpr, ".", configNames)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $XDG_CONFIG_HOME/reginald, filename must be config.
	if !configFound {
		configFound, err = tryConfigDir(
			vpr,
			filepath.Join("${XDG_CONFIG_HOME}", strings.ToLower(constants.Name)),
			[]string{"config"},
		)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $XDG_CONFIG_HOME, matches files without a dot prefix.
	if !configFound {
		configFound, err = tryConfigDir(vpr, "${XDG_CONFIG_HOME}", configNames[:2])
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $HOME/.config/reginald, filename must be config.
	if !configFound {
		configFound, err = tryConfigDir(
			vpr,
			filepath.Join("$HOME", ".config", strings.ToLower(constants.Name)),
			[]string{"config"},
		)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// $HOME/.config, matches files without a dot prefix.
	if !configFound {
		configFound, err = tryConfigDir(vpr, filepath.Join("$HOME", ".config"), configNames[:2])
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	// Home directory.
	if !configFound {
		configFound, err = tryConfigDir(vpr, "$HOME", configNames)
		if err != nil {
			return configFound, fmt.Errorf("%w", err)
		}
	}

	return configFound, nil
}
