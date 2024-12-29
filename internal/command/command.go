package command

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
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
	ExitError   = 1
)

func NewReginaldCommand(ver semver.Version) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct
		Use:     CommandName + " <command> [flags]",
		Short:   Name + " is the workstation valet",
		Long:    `Reginald is the workstation valet for managing your workstation configuration and installed tools.`,
		Version: ver.String(),
		Run:     runHelp,
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

	cmd.AddCommand(bootstrap.NewCommand())
	cmd.AddCommand(version.NewCommand(CommandName, ver))

	cobra.OnInitialize(initConfig(cmd))

	return cmd, nil
}

func initConfig(cmd *cobra.Command) func() {
	return func() {
		setDefaults()

		noColor, err := cmd.Flags().GetBool("no-color")
		if err != nil {
			fmt.Fprintf(os.Stderr, "failed to get the value for the \"no-color\" flag: %v\n", err)
			os.Exit(ExitError)
		}

		if noColor {
			viper.Set("color", false)
		}

		viper.SetEnvPrefix(CommandName)
		viper.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
		viper.AutomaticEnv()

		// Reginald is flexible about the configuration file to use. You can
		// use multiple types of configuration files so the extensions are
		// omitted from the following examples.
		configFound := false

		// Before looking up the config file in the specified locations, see
		// if the command-line flag or the environment variable is set.
		// Because the command-line options has a default value that
		// overrides all of the other sources, start by checking if the
		// option is actually set and then bind it to the Viper config.
		if cmd.Flags().Changed("config-file") {
			err = viper.BindPFlag("config-file", cmd.PersistentFlags().Lookup("config-file"))
			if err != nil {
				fmt.Fprintf(os.Stderr, "failed to bind the flag \"config-file\" to config: %v\n", err)
				os.Exit(ExitError)
			}
		}

		configFile := viper.GetString("config-file")
		if configFile != "" {
			viper.SetConfigFile(configFile)

			configFound = readConfig()
		}

		// First the config is looked for in the current working directory.
		// Files that match: ./reginald
		if !configFound {
			viper.SetConfigName("reginald")
			viper.AddConfigPath(".")

			configFound = readConfig()
		}

		// Next the current working directory but with dot in from of the
		// file. Files that match: ./.reginald
		if !configFound {
			viper.SetConfigName(".reginald")
			viper.AddConfigPath(".")

			configFound = readConfig()
		}

		// Next the XDG_CONFIG_HOME/reginald, defaulting to
		// ~/.config/reginald.
		// TODO: Look for config files in a directory named `reginald` in
		// XDG_CONFIG_HOME.
		if !configFound {
			viper.SetConfigName("reginald")
			viper.AddConfigPath("${XDG_CONFIG_HOME}")
			viper.AddConfigPath("${HOME}/.config")

			configFound = readConfig()
		}

		// Next the user's home directory. If for some reason the user wants
		// to include the config file there without prefixing the filename
		// with a dot, we'll look for that first.
		if !configFound {
			viper.SetConfigName("reginald")
			viper.AddConfigPath("${HOME}")

			configFound = readConfig()
		}

		// Finally the home directory but with a dot in the front.
		if !configFound {
			viper.SetConfigName(".reginald")
			viper.AddConfigPath("${HOME}")

			configFound = readConfig()
		}

		if !viper.GetBool("color") {
			color.NoColor = true
		}

		// TODO: Initialize logging as all the values should now be read.

		if !configFound {
			slog.Warn("Config file not found")
		} else {
			slog.Info(fmt.Sprintf("Read config from file %v", viper.ConfigFileUsed()))
		}

		slog.Info("Running with the following settings", slog.Any("config", viper.AllSettings()))
	}
}

// readConfig is a utility with side effects that reads the Viper config.
// The necessary steps for finding the config should be done before calling this
// function.
// The function returns true if the config file was read, otherwise false.
// If the config file is found but could not be read, the behavior right now is
// to exit the program. This might be changed in the future because now the
// program exists for invalid syntax in the config files.
func readConfig() bool {
	if err := viper.ReadInConfig(); err != nil {
		var notFoundError viper.ConfigFileNotFoundError
		if !errors.As(err, &notFoundError) {
			fmt.Fprintf(os.Stderr, "could not read the configuration file: %v\n", err)
			os.Exit(ExitError)
		}

		return false
	}

	return true
}

func runHelp(cmd *cobra.Command, _ []string) {
	if err := cmd.Help(); err != nil {
		fmt.Fprintln(os.Stderr, "Failed to run the help command")
		os.Exit(ExitError)
	}
}

func setDefaults() {
	viper.SetDefault("color", !color.NoColor)
}
