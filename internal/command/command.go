package command

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/anttikivi/reginald/internal/command/bootstrap"
	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/semver"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

const (
	Name        = "Reginald"
	CommandName = "reginald"
	ExitSuccess = 0
	ExitError   = 1
)

func NewReginaldCommand(ver semver.Version) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct
		Use:   CommandName + " <command> [flags]",
		Short: Name + " is the workstation valet",
		Long: `Reginald is the workstation valet for managing your workstation configuration
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

	err := cmd.PersistentFlags().MarkHidden("no-color")
	if err != nil {
		return nil, fmt.Errorf("failed to mark the no-color flag as hidden: %w", err)
	}

	err = viper.BindPFlag("color", cmd.PersistentFlags().Lookup("color"))
	if err != nil {
		return nil, fmt.Errorf("failed to bind the flag \"color\" to config: %w", err)
	}

	cmd.PersistentFlags().StringP("config-file", "c", "", "path to config file")

	err = cmd.MarkPersistentFlagFilename("config-file", "json", "toml", "yaml", "yml")
	if err != nil {
		return nil, fmt.Errorf("failed to mark the \"config-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().StringP("directory", "C", "", "path to the local dotfiles directory")

	err = cmd.MarkPersistentFlagDirname("directory")
	if err != nil {
		return nil, fmt.Errorf("failed to mark the \"directory\" flag as a filename: %w", err)
	}

	cmd.AddCommand(bootstrap.NewCommand())
	cmd.AddCommand(version.NewCommand(CommandName, ver))

	return cmd, nil
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
		err := viper.BindPFlag(n, cmd.PersistentFlags().Lookup(n))
		if err != nil {
			return fmt.Errorf("failed to bind the flag \"%s\" to config: %w", n, err)
		}
	}

	err := viper.BindEnv(n)
	if err != nil {
		return fmt.Errorf(
			"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
			strings.ReplaceAll(strings.ToUpper(n), "-", "_"),
			err,
		)
	}

	return nil
}

func persistentPreRun(cmd *cobra.Command, _ []string) error {
	setDefaults()

	noColor, err := cmd.Flags().GetBool("no-color")
	if err != nil {
		return fmt.Errorf("failed to get the value for the \"no-color\" flag: %w", err)
	}

	if noColor {
		viper.Set("color", false)
	}

	err = bindPersistentString(cmd, "config-file")
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	err = bindPersistentString(cmd, "directory")
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	viper.SetEnvPrefix(CommandName)
	viper.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
	viper.AutomaticEnv()

	if !viper.GetBool("color") {
		color.NoColor = true
	}

	configFound, err := resolveConfigFile()
	if err != nil {
		return fmt.Errorf("failed to resolve the config file: %w", err)
	}

	// TODO: Initialize logging as all the values should now be read.

	if !configFound {
		slog.Warn("Config file not found")
	} else {
		slog.Info(fmt.Sprintf("Read config from file %v", viper.ConfigFileUsed()))
	}

	slog.Info("Running with the following settings", slog.Any("config", viper.AllSettings()))

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

func runHelp(cmd *cobra.Command, _ []string) error {
	if err := cmd.Help(); err != nil {
		return fmt.Errorf("failed to run the help command: %w", err)
	}

	return nil
}

func setDefaults() {
	viper.SetDefault("color", !color.NoColor)
}
