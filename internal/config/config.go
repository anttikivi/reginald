// Package config contains the program configuration. The configuration is
// parsed from the configuration file, environment variables, and command-line
// arguments.
package config

import (
	"fmt"
	"log/slog"
	"reflect"
	"strings"

	"github.com/anttikivi/reginald/pkg/task"
)

// Config the parsed configuration of the program run. There should be only one
// effective Config per run.
type Config struct {
	Color      bool          // whether colors are enabled in the output
	ConfigFile string        // path to the config file
	Directory  string        // path to the directory passed in with '-C'
	Logging    LoggingConfig // logging config values
	PluginDir  string        // directory where Reginald looks for plugins
	Quiet      bool          // whether only errors are output
	Tasks      []task.Config // tasks configs
	Verbose    bool          // whether verbose output is enabled
}

// LoggingConfig is type of the logging configuration in Config.
type LoggingConfig struct {
	Enabled bool       `toml:"enabled"` // whether logging is enabled
	Format  string     `toml:"format"`  // format of the logs, "json" or "text"
	Level   slog.Level `toml:"level"`   // logging level
	Output  string     `toml:"output"`  // destination of the logs
}

// A File is a struct that the represents the structure of a valid configuration
// file. It is a subset of [Config]. Some of the configuration values may not
// be set using the file so the file is first unmarshaled into a File and the
// values are read into [Config].
//
// See the documentation for each field in [Config].
type File struct {
	Color     bool             `toml:"color"`
	Logging   LoggingConfig    `toml:"logging"`
	PluginDir string           `toml:"plugin-dir"`
	Quiet     bool             `toml:"quiet"`
	Tasks     []map[string]any `toml:"tasks"`
	Verbose   bool             `toml:"verbose"`
}

// Equal reports if the Config that d points to is equal to the Config that c
// points to.
func (c *Config) Equal(d *Config) bool {
	if c == d {
		return true
	}

	if c == nil {
		return d == nil
	}

	if d == nil {
		return c == nil
	}

	if len(c.Tasks) != len(d.Tasks) {
		return false
	}

	for i, t := range c.Tasks {
		u := d.Tasks[i]

		if t.Type != u.Type || t.Name != u.Name {
			return false
		}

		for k, a := range t.Settings {
			if b, ok := u.Settings[k]; !ok || a != b {
				return false
			}
		}
	}

	return c.Color == d.Color && c.ConfigFile == d.ConfigFile && c.Directory == d.Directory &&
		c.Logging == d.Logging &&
		c.PluginDir == d.PluginDir &&
		c.Quiet == d.Quiet &&
		c.Verbose == d.Verbose
}

// from creates a new [Config] by creating one with default values and then
// applying all of the found values from f.
func (f *File) from() (*Config, error) {
	cfg := defaultConfig()
	cfgValue := reflect.ValueOf(cfg).Elem()
	cfgFile := reflect.ValueOf(f).Elem()

	applyFileValues(cfgFile, cfgValue)

	if len(f.Tasks) > 0 {
		if err := applyTasks(f, cfg); err != nil {
			return nil, fmt.Errorf("%w", err)
		}
	}

	return cfg, nil
}

// applyFileValues applies the configuration values from the value of
// [File] given as the first parameter to the value [Config] given as
// the second parameter. It calls itself recursively to resolve structs. It
// panics if there is an error.
func applyFileValues(cfgFile, cfg reflect.Value) {
	for i := range cfgFile.NumField() {
		fieldValue := cfgFile.Field(i)
		structField := cfgFile.Type().Field(i)
		target := cfg.FieldByName(structField.Name)

		if !target.IsValid() || !target.CanSet() {
			panic("target value in Config cannot be set: " + structField.Name)
		}

		// Tasks are handled manually in [File.from].
		if strings.ToLower(structField.Name) == "tasks" {
			continue
		}

		if fieldValue.Kind() == reflect.Struct {
			applyFileValues(fieldValue, target)

			continue
		}

		if !fieldValue.Type().AssignableTo(target.Type()) {
			panic(
				fmt.Sprintf(
					"config file value from field %q is not assignable to config",
					structField.Name,
				),
			)
		}

		target.Set(fieldValue)
	}
}

// applyTasks copies the task configurations from cfgFile to cfg. It modifies
// the pointed Config directly.
func applyTasks(cfgFile *File, cfg *Config) error {
	cfg.Tasks = make([]task.Config, len(cfgFile.Tasks))
	counters := map[string]int{}

	for i, m := range cfgFile.Tasks {
		var t task.Config

		taskType, ok := m["type"]
		if !ok {
			return fmt.Errorf("%w: task does not specify a type", errInvalidConfig)
		}

		typeString, ok := taskType.(string)
		if !ok {
			return fmt.Errorf("%w: task type is not a string: %v", errInvalidConfig, m["type"])
		}

		t.Type = typeString

		if taskName, ok := m["name"]; ok {
			nameString, ok := taskName.(string)
			if !ok {
				return fmt.Errorf("%w: task name is not a string: %v", errInvalidConfig, m["name"])
			}

			t.Name = nameString
		} else {
			count, ok := counters[typeString]
			if !ok {
				count = 0
			}

			nameString := fmt.Sprintf("%s-%v", typeString, count)
			t.Name = nameString
			count++
			counters[typeString] = count
		}

		t.Settings = make(map[string]any, len(m)-2) //nolint:mnd

		for k, v := range m {
			k = strings.ToLower(k)
			if k == "type" || k == "name" {
				continue
			}

			t.Settings[k] = v
		}

		cfg.Tasks[i] = t
	}

	return nil
}
