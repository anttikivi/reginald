package command

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/anttikivi/reginald/internal/command/bootstrap"
	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/anttikivi/reginald/internal/semver"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

const (
	defaultLogFormat  = "json"
	defaultLogLevel   = "info"
	rotateLogsDefault = true
)

func GetDefaultConfigFile() string {
	return strings.ToLower(constants.Name) + ".log"
}

func NewReginaldCommand(ver semver.Version) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct
		Use:   constants.CommandName + " command [flags]",
		Short: constants.Name + " is the workstation valet",
		Long: constants.Name + ` is the workstation valet for managing your workstation configuration
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

	if err := cmd.PersistentFlags().MarkHidden("no-color"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"no-color\" flag as hidden: %w", err)
	}

	if err := viper.BindPFlag("color", cmd.PersistentFlags().Lookup("color")); err != nil {
		return nil, fmt.Errorf("failed to bind the flag \"color\" to config: %w", err)
	}

	cmd.PersistentFlags().StringP("config-file", "c", "", "path to config file")

	if err := cmd.MarkPersistentFlagFilename("config-file", "json", "toml", "yaml", "yml"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"config-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().StringP("directory", "C", "", "path to the local dotfiles directory")

	if err := cmd.MarkPersistentFlagDirname("directory"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"directory\" flag as a dirname: %w", err)
	}

	// Logging options.
	cmd.PersistentFlags().String(
		"log-destination",
		"file",
		"destination for the logs, possible values are: file or filename, stderr, stdout, nil, none, null, and /dev/null",
	)
	cmd.PersistentFlags().Bool("log-stderr", false, "print logs to stderr")
	cmd.PersistentFlags().Bool("log-stdout", false, "print logs to stdout")
	cmd.PersistentFlags().Bool("log-null", false, "disables logging")
	cmd.PersistentFlags().Bool("disable-logs", false, "disables logging")
	cmd.PersistentFlags().Bool("no-logs", false, "disables logging")
	cmd.MarkFlagsMutuallyExclusive("log-destination", "log-stderr", "log-stdout", "log-null", "disable-logs", "no-logs")

	if err := cmd.PersistentFlags().MarkHidden("log-stderr"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-stderr\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("log-stdout"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-stdout\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("log-null"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-null\" flag as hidden: %w", err)
	}

	if err := cmd.PersistentFlags().MarkHidden("disable-logs"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"disable-logs\" flag as hidden: %w", err)
	}

	cmd.PersistentFlags().String("log-file", GetDefaultConfigFile(), "path to the log file, if logs are output to a file")

	if err := cmd.MarkPersistentFlagFilename("log-file"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"log-file\" flag as a filename: %w", err)
	}

	cmd.PersistentFlags().String(
		"log-level",
		"info",
		"logging level to use, possible values are: debug, info, warn (or warning), error (or err), and off",
	)
	cmd.PersistentFlags().String("log-format", defaultLogFormat, "format for the logs, possible values are: json and text")

	cmd.PersistentFlags().Bool("no-log-rotation", !rotateLogsDefault, "disable the built-in log rotation")
	cmd.PersistentFlags().Bool("disable-log-rotation", !rotateLogsDefault, "disable the built-in log rotation")
	cmd.MarkFlagsMutuallyExclusive("no-log-rotation", "disable-log-rotation")

	if err := cmd.PersistentFlags().MarkHidden("disable-log-rotation"); err != nil {
		return nil, fmt.Errorf("failed to mark the \"disable-log-rotation\" flag as hidden: %w", err)
	}

	cmd.AddCommand(bootstrap.NewCommand())
	cmd.AddCommand(version.NewCommand(ver))

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

// normalizeLogDestination checks the values set for `log-destination`
// normalizes the values that the user can set to it.
func normalizeLogDestination() {
	configName := "log-destination"

	switch v := viper.GetString(configName); v {
	case "stderr", "stdout", "file":
		viper.Set(configName, v)
	case "nil", "none", "null", "/dev/null":
		viper.Set(configName, "none")
	default:
		// For the default case, we assume the user gave a filename.
		viper.Set(configName, "file")
		viper.Set("log-file", v)
	}
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

	err = bindPersistentString(cmd, "log-file")
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	err = bindPersistentString(cmd, "log-format")
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	err = bindPersistentString(cmd, "log-level")
	if err != nil {
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

	configFound, err := resolveConfigFile()
	if err != nil {
		return fmt.Errorf("failed to resolve the config file: %w", err)
	}

	if err := initLogging(cmd); err != nil {
		return fmt.Errorf("failed to init logging: %w", err)
	}

	slog.Info("Starting a new Reginald run", "command", cmd.Name())
	slog.Info("Logging initialized", "rotate-logs", viper.GetBool("rotate-logs"))

	if !configFound {
		slog.Warn("Config file not found")
	} else {
		slog.Info("Config file read", "config-file", viper.ConfigFileUsed())
	}

	slog.Info("Running with the following settings", slog.Any("config", viper.AllSettings()))

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

	// If the log level is set to `off`, the destination for log is overridden
	// and logs will be disabled.
	levelName := viper.GetString("log-level")
	if levelName == "off" {
		viper.Set("log-destination", "none")
	}

	logLevel, err := logging.GetLevel(levelName)
	if err != nil {
		return fmt.Errorf("failed to get the log level: %w", err)
	}

	// Create the correct writer for the logs.
	logWriter, err := logging.GetWriter(
		viper.GetString("log-destination"),
		viper.GetString("log-file"),
		viper.GetBool("rotate-logs"),
	)
	if err != nil {
		return fmt.Errorf("failed to get the log writer: %w", err)
	}

	logHandler, err := logging.CreateHandler(logWriter, viper.GetString("log-format"), logLevel)
	if err != nil {
		return fmt.Errorf("failed to create the log handler: %w", err)
	}

	logger := slog.New(logHandler)

	slog.SetDefault(logger)

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
	viper.SetDefault("log-destination", "file")
	viper.SetDefault("log-file", GetDefaultConfigFile())
	viper.SetDefault("log-format", defaultLogFormat)
	viper.SetDefault("log-level", defaultLogLevel)
	viper.SetDefault("rotate-logs", rotateLogsDefault)
}

func parseLogDestination(cmd *cobra.Command) error {
	configName := "log-destination"

	// Check the different command-line arguments and see if they are set. As
	// command-line options override options from other sources, set the values
	// according to them if they are set. Otherwise the other sources are used.
	switch {
	case cmd.Flags().Changed(configName):
		if err := viper.BindPFlag(configName, cmd.PersistentFlags().Lookup(configName)); err != nil {
			return fmt.Errorf("failed to bind the flag \"%s\" to config: %w", configName, err)
		}
	case cmd.Flags().Changed("log-stderr"):
		v, err := cmd.Flags().GetBool("log-stderr")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stderr\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "stderr")
		}
	case cmd.Flags().Changed("log-stdout"):
		v, err := cmd.Flags().GetBool("log-stdout")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-stdout\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "stdout")
		}
	case cmd.Flags().Changed("log-null"):
		v, err := cmd.Flags().GetBool("log-null")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"log-null\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "none")
		}
	case cmd.Flags().Changed("disable-logs"):
		v, err := cmd.Flags().GetBool("disable-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"disable-logs\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "none")
		}
	case cmd.Flags().Changed("no-logs"):
		v, err := cmd.Flags().GetBool("no-logs")
		if err != nil {
			return fmt.Errorf("failed to get the value for the \"no-logs\" flag: %w", err)
		}

		if v {
			viper.Set(configName, "none")
		}
	}

	return nil
}

// setLogDestination checks the different possible flags and environment
// variables that can be set for `log-destination` and sets the
// `log-destination` config value correctly.
func setLogDestination(cmd *cobra.Command) error {
	var (
		configName    = "log-destination"
		configAliases = []string{"log-stderr", "log-stdout", "log-null", "disable-logs", "no-logs"}
	)

	if err := viper.BindEnv(configName); err != nil {
		return fmt.Errorf(
			"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
			strings.ReplaceAll(strings.ToUpper(configName), "-", "_"),
			err,
		)
	}

	for _, alias := range configAliases {
		if err := viper.BindEnv(alias); err != nil {
			return fmt.Errorf(
				"failed to bind the environment variable \"REGINALD_%s\" to config: %w",
				strings.ReplaceAll(strings.ToUpper(alias), "-", "_"),
				err,
			)
		}
	}

	if err := parseLogDestination(cmd); err != nil {
		return fmt.Errorf("failed to parse the log destination: %w", err)
	}

	// Ensure that the value set for the logs destination is correct.
	normalizeLogDestination()

	return nil
}
