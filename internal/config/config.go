package config

import (
	"errors"
	"fmt"
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/fatih/color"
	"github.com/mitchellh/mapstructure"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// Config is a parsed configuration instance for an application run. It is
// unmarshaled from the Viper instance for the run after parsing the values from
// the configuration sources.
type Config struct {
	// BaseDirectory is the directory of operations for the program. It should
	// be the local directory with the so-called dotfiles.
	BaseDirectory string `mapstructure:"directory"`

	// ConfigFile is the path to the resolved config file.
	ConfigFile string `mapstructure:"config-file"`

	// Log contains the configuration for logging.
	Log logging.Config `mapstructure:"log"`

	// Repository is the remote Git repository that contains the so-called
	// dotfiles. Initially it contains the value that the user set in the
	// configuration but it is replaced by the resolved URL in the command.
	Repository string `mapstructure:"repository"`

	// UseColor tells whether the program should output colors to the terminal.
	UseColor bool `mapstructure:"color"`
}

const (
	// KeyColor is the config key for the value that enforces colors in output.
	KeyColor = "color"

	// KeyConfigFile is the config key for the config file value.
	KeyConfigFile = "config-file"

	// KeyDirectory is the config key for the base directory value.
	KeyDirectory = "directory"

	// KeyRepository is the config key for the remote repository.
	KeyRepository = "repository"
)

// ErrConfigType is error for cases where a value given in the config is the
// wrong type.
var ErrConfigType = errors.New("invalid config type")

// EnvReplacer is the [strings.Replacer] used to format the config key for
// binding with environment variables.
//
//nolint:gochecknoglobals // Shared within the process, used like a constant.
var EnvReplacer = strings.NewReplacer("-", "_", ".", "_")

// Init initializes the Viper instance for the current run. It resolves the
// configuration values needed for unmarshaling into [Config]. It returns an
// error for errors that are caused by invalid configuration (user error), and
// panics if there are actual problems with the program.
func Init(vpr *viper.Viper, cmd *cobra.Command) error {
	noColor, err := cmd.Flags().GetBool("no-color")
	if err != nil {
		panic(
			exit.New(exit.CommandInitFailure, fmt.Errorf("failed to get the value for the \"no-color\" flag: %w", err)),
		)
	}

	if noColor {
		vpr.Set(KeyColor, false)
	}

	bindString(vpr, cmd, KeyConfigFile, "config-file")
	bindString(vpr, cmd, KeyDirectory, "directory")
	bindString(vpr, cmd, KeyRepository, "")
	bindString(vpr, cmd, logging.KeyFormat, "log-format")
	bindString(vpr, cmd, logging.KeyLevel, "log-level")
	bindString(vpr, cmd, logging.KeyPlain, "plain-logs")

	// Check the log rotation. There are two command-line flags that can be used
	// to disable rotating log; check if either of them have been changed and
	// set the `rotate-logs` config value to false if so. Command-line flags
	// take precedence over other sources so using the manual `Set` is also
	// safe.
	if cmd.Flags().Changed("no-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("no-log-rotation")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"no-log-rotation\" flag: %w", err),
				),
			)
		}

		if noLogRotation {
			vpr.Set(logging.KeyRotate, false)
		}
	}

	if cmd.Flags().Changed("disable-log-rotation") {
		noLogRotation, err := cmd.Flags().GetBool("disable-log-rotation")
		if err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to get the value for the \"disable-log-rotation\" flag: %w", err),
				),
			)
		}

		if noLogRotation {
			vpr.Set(logging.KeyRotate, false)
		}
	}

	setDefaults(vpr)

	// vpr.SetEnvPrefix(constants.CommandName)
	vpr.SetEnvPrefix(strings.ToLower(constants.Name))
	vpr.SetEnvKeyReplacer(EnvReplacer)
	vpr.AutomaticEnv()

	if _, err := resolveConfigFile(vpr); err != nil {
		// If the config file cannot be read, it is probably caused by the fact
		// that the file format is wrong. Therefore it's most likely not a
		// problem with the program.
		return fmt.Errorf("%w", err)
	}

	if !logging.CanFastInit(cmd) {
		if err := parseLoggingConfig(vpr, cmd); err != nil {
			return exit.New(exit.InvalidConfig, fmt.Errorf("%w", err))
		}
	}

	return nil
}

// Parse parses the configuration for the current run. It returns an error for
// errors that are caused by invalid configuration (user error), and panics if
// there are actual problems with the program.
func Parse(vpr *viper.Viper) (*Config, error) {
	m := vpr.AllSettings()

	logm, ok := m["log"].(map[string]any)
	if !ok {
		panic(
			exit.New(
				exit.InvalidConfig,
				fmt.Errorf("%w: value for \"log\" cannot be cast to map[string]any", ErrConfigType),
			),
		)
	}

	// Remove the log output aliases from the map.
	for _, s := range logging.AllOutputKeys {
		if s != logging.KeyOutput {
			delete(logm, strings.TrimPrefix(s, "log."))
		}
	}

	cleanVpr := viper.New()
	setDefaults(cleanVpr)

	for k, v := range m {
		cleanVpr.Set(k, v)
	}

	var cfg *Config

	decoderOpts := viper.DecodeHook(
		mapstructure.ComposeDecodeHookFunc(
			mapstructure.StringToTimeDurationHookFunc(),
			mapstructure.StringToSliceHookFunc(","),
			mapstructure.TextUnmarshallerHookFunc(),
		),
	)

	if err := cleanVpr.UnmarshalExact(&cfg, decoderOpts); err != nil {
		return nil, exit.New(
			exit.InvalidConfig,
			fmt.Errorf("%w: failed to convert the parsed config to `Config`: %w", ErrConfigType, err),
		)
	}

	// I think this is stupid but still a fine way to pass the color information
	// to the logging init.
	cfg.Log.UseColor = cfg.UseColor

	return cfg, nil
}

// setDefaults sets the default settings to the given Viper instance. If parsed
// is set to true, the function sets the real, parsed values to the correct keys
// instead of intermediate values used while parsing the config sources.
func setDefaults(vpr *viper.Viper) {
	vpr.SetDefault(KeyColor, !color.NoColor)
	vpr.SetDefault(KeyConfigFile, "")
	vpr.SetDefault(KeyDirectory, DefaultDirectory)
	vpr.SetDefault(KeyRepository, "")
	vpr.SetDefault(logging.KeyPlain, logging.DefaultPlain)
	vpr.SetDefault(logging.KeyFile, logging.DefaultFile)
	vpr.SetDefault(logging.KeyFormat, logging.DefaultValueFormat)
	vpr.SetDefault(logging.KeyLevel, logging.DefaultValueLevel)
	vpr.SetDefault(logging.KeyOutput, logging.DefaultValueOutput)
	vpr.SetDefault(logging.KeyRotate, logging.DefaultRotate)
}

// bindString binds a Viper config value to an environment variable and,
// optionally, to a flag. The config key must be given. If flag is an empty
// string, it won't be bound.
func bindString(vpr *viper.Viper, cmd *cobra.Command, key, flag string) {
	if flag != "" {
		if err := vpr.BindPFlag(key, cmd.Flags().Lookup(flag)); err != nil {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to bind the flag %q to config %q: %w", flag, key, err),
				),
			)
		}
	}

	if err := vpr.BindEnv(key); err != nil {
		panic(
			exit.New(
				exit.CommandInitFailure,
				fmt.Errorf(
					"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
					EnvReplacer.Replace(strings.ToUpper(key)),
					err,
				),
			),
		)
	}
}
