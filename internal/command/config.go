package command

import (
	"fmt"
	"strings"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

func NewViper() *viper.Viper {
	return viper.New()
}

func setDefaults(vpr *viper.Viper) {
	vpr.SetDefault(config.KeyColor, !color.NoColor)
	vpr.SetDefault(config.KeyConfigFile, "")
	vpr.SetDefault(config.KeyDirectory, "~/tmp")
	vpr.SetDefault(config.KeyLogFile, config.DefaultLogFile)
	vpr.SetDefault(config.KeyLogFormat, config.DefaultLogFormat)
	vpr.SetDefault(config.KeyLogLevel, config.DefaultLogLevel)
	vpr.SetDefault(config.KeyLogOutput, config.ValueLogOutputFile)
	vpr.SetDefault(config.KeyRotateLogs, config.DefaultRotateLogs)
}

// bindString binds a Viper config value to a persistent flag string if that
// string has been set by the user with a command-line argument. This additional
// check is needed because the command-line arguments always have a default
// value, usually an empty string, that would otherwise override the Viper
// default or values from other sources. This function also binds the values to
// the environment variables so that the values are included in all settings if
// the environment variables are set.
func bindString(vpr *viper.Viper, cmd *cobra.Command, key, flag string) {
	if err := vpr.BindPFlag(key, cmd.Flags().Lookup(flag)); err != nil {
		panic(fmt.Sprintf("failed to bind the flag %q to config %q: %v", flag, key, err))
	}

	if err := vpr.BindEnv(key); err != nil {
		panic(
			fmt.Sprintf(
				"failed to bind the environment variable \"REGINALD_%s\" to config: %v",
				strings.ReplaceAll(strings.ToUpper(key), "-", "_"),
				err,
			),
		)
	}
}

// initRootConfig initializes the configuration for the current run.
func initRootConfig(vpr *viper.Viper, cmd *cobra.Command) (*config.Config, error) {
	noColor, err := cmd.Flags().GetBool("no-color")
	if err != nil {
		return nil, fmt.Errorf("failed to get the value for the \"no-color\" flag: %w", err)
	}

	if noColor {
		vpr.Set(config.KeyColor, false)
	}

	bindString(vpr, cmd, config.KeyConfigFile, "config-file")
	bindString(vpr, cmd, config.KeyDirectory, "directory")
	bindString(vpr, cmd, config.KeyLogFormat, "log-format")
	bindString(vpr, cmd, config.KeyLogLevel, "log-level")

	// Check the log rotation.
	// There are two command-line flags that can be used to disable rotating
	// log; check if either of them have been changed and set the `rotate-logs`
	// config value to false if so.
	// Command-line flags take precedence over other sources so using the manual
	// `Set` is also safe.
	if cmd.Flags().Changed("no-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("no-log-rotation")
		if err != nil {
			return nil, fmt.Errorf("failed to get the value for the \"no-log-rotation\" flag: %w", err)
		}

		if noLogRotation {
			vpr.Set(config.KeyRotateLogs, false)
		}
	}

	if cmd.Flags().Changed("disable-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("disable-log-rotation")
		if err != nil {
			return nil, fmt.Errorf("failed to get the value for the \"disable-log-rotation\" flag: %w", err)
		}

		if noLogRotation {
			vpr.Set(config.KeyRotateLogs, false)
		}
	}

	setDefaults(vpr)

	// vpr.SetEnvPrefix(constants.CommandName)
	vpr.SetEnvPrefix(strings.ToLower(constants.Name))
	vpr.SetEnvKeyReplacer(strings.NewReplacer("-", "_"))
	vpr.AutomaticEnv()

	if _, err := resolveConfigFile(vpr); err != nil {
		return nil, fmt.Errorf("failed to resolve the config file: %w", err)
	}

	if !vpr.GetBool(config.KeyColor) {
		color.NoColor = true
	}

	if err := initLogging(vpr, cmd); err != nil {
		return nil, fmt.Errorf("failed to init logging: %w", err)
	}

	var cfg *config.Config

	if err := vpr.UnmarshalExact(cfg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal the config: %w", err)
	}

	return cfg, nil
}
