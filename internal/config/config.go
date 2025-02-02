// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package config

import (
	"errors"
	"fmt"
	"os"
	"reflect"
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/git"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/anttikivi/reginald/internal/paths"
	"github.com/anttikivi/reginald/internal/plugins"
	"github.com/anttikivi/reginald/pkg/task"
	"github.com/fatih/color"
	"github.com/mitchellh/mapstructure"
	"github.com/pelletier/go-toml/v2"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// Config is a parsed configuration instance for an application run. It is
// unmarshaled from the Viper instance for the run after parsing the values from
// the configuration sources.
type Config struct {
	// BaseDirectory is the directory of operations for the program. It should
	// be the local directory with the so-called dotfiles.
	BaseDirectory string `mapstructure:"base-directory"`

	// ConfigFile is the path to the resolved config file.
	ConfigFile string `mapstructure:"config-file"`

	// Defaults contains the default settings for tasks.
	Defaults map[string]task.Settings

	// DisableHTTPSInit marks whether to disable using HTTPS during the initial
	// repository cloning while the boostrapping. By default, the program uses
	// HTTPS instead of the specified protocol to initially clone the dotfiles
	// repository in order to allow using the files in dotfiles to set up the
	// required credentials to use SSH later.
	DisableHTTPSInit bool `mapstructure:"disable-https-init"`

	// DryRun marks the current run as a "dry run" so that the command only
	// prints what it would have done instead of actually doing anything.
	DryRun bool `mapstructure:"dry-run"`

	// GitProtocol is the protocol used in cloning the remote repository if the
	// given repository is not a full URL.
	GitProtocol git.Protocol `mapstructure:"git-protocol"`

	// GitSSHUser is the SSH user to use in cloning the remote repository if the
	// given repository is not a full URL and SSH is used for cloning the
	// repository.
	GitSSHUser string `mapstructure:"git-ssh-user"`

	// Log contains the configuration for logging.
	Log logging.Config

	// PluginInfos contains the parsed information on the available plugins.
	PluginInfos []plugins.PluginInfo

	// PluginsDir is the directory where the program tries to find the plugin
	// executables.
	PluginsDir string `mapstructure:"plugins-directory"`

	// Quiet tells whether the command's output has been disabled.
	Quiet bool

	// RepositoryName is the remote Git repository that contains the so-called
	// dotfiles. This field contains that value the user has given. The parsed
	// URL is stored in the Repository field.
	Repository string

	// RepositoryHostname is the Git hostname used for cloning the remote
	// repository if the given repository is not a full URL.
	RepositoryHostname string `mapstructure:"git-host"`

	// Tasks contains the task configs.
	Tasks task.ConfigList

	// UseColor tells whether the program should output colors to the terminal.
	UseColor bool `mapstructure:"color"`

	// Verbose tells whether the command should print more detailed output
	// during its run.
	Verbose bool
}

// Configuration keys that are used to get and store that config values. The
// program expects these same keys to be used in the config files.
const (
	KeyColor              = "color"
	KeyConfigFile         = "config-file"
	KeyDirectory          = "base-directory"
	KeyDisableHTTPSInit   = "disable-https-init"
	KeyDryRun             = "dry-run"
	KeyGitProtocol        = "git-protocol"
	KeyGitSSHUser         = "git-ssh-user"
	KeyPluginsDir         = "plugins-directory"
	KeyQuiet              = "quiet"
	KeyRepository         = "repository"
	KeyRepositoryHostname = "git-host"
	KeyVerbose            = "verbose"
)

// Default values for the remote repository configuration.
const (
	// DefaultDisableHTTPSInit is the default config value for the flag that
	// determines whether to skip the forced HTTPS clone in bootstrapping.
	DefaultDisableHTTPSInit = false

	// DefaultGitProtocol is the default protocol used for cloning the remote
	// repository if the given repository is not a full URL.
	DefaultGitProtocol = git.HTTPS

	// DefaultGitSSHUser is the default SSH user to use for cloning the remote
	// repository if the given repository is not a full URL and SSH is used for
	// cloning the repository.
	DefaultGitSSHUser = "git"

	// DefaultRepositoryHostname is the default hostname to use for cloning the
	// remote repository if the given repository is not a full URL.
	DefaultRepositoryHostname = "github.com"
)

// ErrConfigType is error for cases where a value given in the config is the
// wrong type.
var ErrConfigType = errors.New("invalid config type")

// Errors for fixing the configuration keys manually.
var (
	// errConfigFileType is error for cases where we try to manually read the
	// config file for fixing the keys but the file type is unsupported.
	errConfigFileType = errors.New("the config file uses unsupported file type")

	// errInvalidValueType is error for cases where a config entry has invalid
	// type during fixing the keys.
	errInvalidValueType = errors.New("value in the configuration has an invalid type")

	// errMissingTaskKey is error for when a task config doesn't have a key it
	// is supposed to have.
	errMissingTaskKey = errors.New("a task does not contain key")
)

// EnvReplacer is the [strings.Replacer] used to format the config key for
// binding with environment variables.
//
//nolint:gochecknoglobals // Shared within the process, used like a constant.
var EnvReplacer = strings.NewReplacer("-", "_", ".", "_")

// BindString binds a Viper config value to an environment variable and,
// optionally, to a flag. The config key must be given. If flag is an empty
// string, it won't be bound.
func BindString(vpr *viper.Viper, cmd *cobra.Command, key, flag string) {
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

// HasFastInit reports whether the given command should skip the lengthy
// initialization steps, e.g. plugin search and logging initialization.
func HasFastInit(cmd *cobra.Command) bool {
	if cmd == nil {
		return false
	}

	if cmd.Annotations == nil {
		return false
	}

	if fastInit, ok := cmd.Annotations["cmd_fast_init"]; ok {
		return fastInit == "true"
	}

	return false
}

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

	BindString(vpr, cmd, KeyConfigFile, "config-file")
	BindString(vpr, cmd, KeyDirectory, "directory")
	BindString(vpr, cmd, KeyPluginsDir, "plugins-dir")
	BindString(vpr, cmd, KeyRepository, "")
	BindString(vpr, cmd, logging.KeyFormat, "log-format")
	BindString(vpr, cmd, logging.KeyLevel, "log-level")

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

	if !HasFastInit(cmd) {
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

	if f, ok := m["config-file"]; (!ok || f == "") && FileFound(vpr) {
		cleanVpr.Set(KeyConfigFile, vpr.ConfigFileUsed())
	}

	var cfg *Config

	decoderOpts := viper.DecodeHook(
		mapstructure.ComposeDecodeHookFunc(
			mapstructure.StringToTimeDurationHookFunc(),
			mapstructure.StringToSliceHookFunc(","),
			mapstructure.TextUnmarshallerHookFunc(),
		),
	)

	if err := cleanVpr.UnmarshalExact(&cfg, decoderOpts, func(c *mapstructure.DecoderConfig) {
		c.MatchName = func(mapKey, fieldName string) bool {
			if strings.Contains(mapKey, "/") || strings.Contains(mapKey, "\\") || strings.Contains(mapKey, "$") || strings.Contains(mapKey, "%") {
				return mapKey == fieldName
			}

			return strings.EqualFold(mapKey, fieldName)
		}
	}); err != nil {
		return nil, exit.New(
			exit.InvalidConfig,
			fmt.Errorf("%w: failed to convert the parsed config to `Config`: %w", ErrConfigType, err),
		)
	}

	// I think this is stupid but still a fine way to pass the color information
	// to the logging init.
	cfg.Log.UseColor = cfg.UseColor

	cfg, err := fixKeys(vpr, cfg)
	if err != nil {
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("failed to fix config keys: %w", err))
	}

	cfg, err = cleanPaths(cfg)
	if err != nil {
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("failed to clean config paths: %w", err))
	}

	return cfg, nil
}

// fixKeys fixes the configuration keys that need to be case-sensitive but are
// converted to lower case by Viper.
//
// NOTE: This is quite inefficient but probably fine for the use case.
func fixKeys(vpr *viper.Viper, cfg *Config) (*Config, error) {
	if !FileFound(vpr) {
		return cfg, nil
	}

	file := vpr.ConfigFileUsed()

	// NOTE: Right now, we only support TOML files.
	if !strings.HasSuffix(file, ".toml") {
		return nil, fmt.Errorf("%w: %v", errConfigFileType, file)
	}

	var fileMap map[string]any

	cfgFileContents, err := os.ReadFile(file)
	if err != nil {
		return nil, fmt.Errorf("failed to open the config file: %w", err)
	}

	if err := toml.Unmarshal(cfgFileContents, &fileMap); err != nil {
		return nil, fmt.Errorf("failed to unmarshal the config file: %w", err)
	}

	if _, ok := fileMap["tasks"]; !ok {
		return cfg, nil
	}

	fileTasks, ok := fileMap["tasks"].([]any)
	if !ok {
		return nil, fmt.Errorf("%w: key %q, got %v: %v", errInvalidValueType, "tasks", reflect.TypeOf(fileMap["tasks"]), fileMap["tasks"])
	}

	fileLinkTasks := make([]map[string]any, 0)

	for i, rawFileTask := range fileTasks {
		fileTaskCfg, ok := rawFileTask.(map[string]any)
		if !ok {
			return nil, fmt.Errorf("%w: key %q.[%d], got %v: %v", errInvalidValueType, "tasks", i, reflect.TypeOf(rawFileTask), rawFileTask)
		}

		fileTaskType, ok := fileTaskCfg["type"]
		if !ok {
			return nil, fmt.Errorf("%w: %q: %v", errMissingTaskKey, "type", fileTaskCfg)
		}

		if t, ok := fileTaskType.(string); !ok {
			return nil, fmt.Errorf("%w: the type of the task is not a string but %v", errInvalidValueType, reflect.TypeOf(fileTaskType))
		} else if t != "link" {
			// NOTE: Right now, the only task that required this is the "link"
			// task.
			continue
		}

		fileLinkTasks = append(fileLinkTasks, fileTaskCfg)
	}

	newTasksCfg := make(task.ConfigList, 0)

	for _, taskCfg := range cfg.Tasks {
		if taskCfg.Type != "link" {
			newTasksCfg = append(newTasksCfg, taskCfg)

			continue
		}

		for _, fileTask := range fileLinkTasks {
			rawFileLinks, ok := fileTask["links"]
			if !ok {
				return nil, fmt.Errorf("%w: %q: %v", errMissingTaskKey, "links", fileTask)
			}

			fileLinks, ok := rawFileLinks.(map[string]any)
			if !ok {
				// Just skip the entry as they are validated elsewhere.
				continue
			}

			for key := range fileLinks {
				cfgLinks, ok := taskCfg.Settings["links"]
				if !ok {
					return nil, fmt.Errorf("%w: %q: %v", errMissingTaskKey, "links", taskCfg)
				}

				cfgLinkMap, ok := cfgLinks.(map[string]any)
				if !ok {
					continue
				}

				newLinks := make(map[string]any, 0)

				for target, value := range cfgLinkMap {
					if strings.EqualFold(key, target) {
						newLinks[key] = value
					}
				}

				taskCfg.Settings["links"] = newLinks
			}
		}

		newTasksCfg = append(newTasksCfg, taskCfg)
	}

	cfg.Tasks = newTasksCfg

	return cfg, nil
}

// cleanPaths cleans the paths in the config instance and makes them absolute.
// It also resolves home directories and environment variables in them.
func cleanPaths(cfg *Config) (*Config, error) {
	var (
		p   string
		err error
	)

	p, err = paths.Abs(cfg.BaseDirectory)
	if err != nil {
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("failed to turn %q to an absolute path: %w", p, err))
	}

	cfg.BaseDirectory = p

	p, err = paths.Abs(cfg.ConfigFile)
	if err != nil {
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("failed to turn %q to an absolute path: %w", p, err))
	}

	cfg.ConfigFile = p

	p, err = paths.Abs(cfg.Log.File)
	if err != nil {
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("failed to turn %q to an absolute path: %w", p, err))
	}

	cfg.Log.File = p

	return cfg, nil
}

// setDefaults sets the default settings to the given Viper instance. If parsed
// is set to true, the function sets the real, parsed values to the correct keys
// instead of intermediate values used while parsing the config sources.
func setDefaults(vpr *viper.Viper) {
	vpr.SetDefault(KeyColor, !color.NoColor)
	vpr.SetDefault(KeyConfigFile, "")
	vpr.SetDefault(KeyDirectory, DefaultDirectory)
	vpr.SetDefault(KeyGitProtocol, DefaultGitProtocol.String())
	vpr.SetDefault(KeyGitSSHUser, DefaultGitSSHUser)
	vpr.SetDefault(KeyPluginsDir, plugins.DefaultDir)
	vpr.SetDefault(KeyRepository, "")
	vpr.SetDefault(KeyRepositoryHostname, DefaultRepositoryHostname)
	vpr.SetDefault(KeyDisableHTTPSInit, DefaultDisableHTTPSInit)
	vpr.SetDefault(logging.KeyFile, logging.DefaultFile)
	vpr.SetDefault(logging.KeyFormat, logging.DefaultFormat.String())
	vpr.SetDefault(logging.KeyLevel, logging.DefaultLevel.String())
	vpr.SetDefault(logging.KeyOutput, logging.DefaultOutput.String())
	vpr.SetDefault(logging.KeyRotate, logging.DefaultRotate)
}
