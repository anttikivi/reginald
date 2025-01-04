package config

import (
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
)

// Config is a parsed configuration instance for an application run. It is
// unmarshaled from the Viper instance for the run after parsing the values from
// the configuration sources.
type Config struct {
	configFile string `mapstructure:"config-file"`
}

const (
	// DefaultLogFormat is the initial default value for the `log-format` value.
	// The default is later determined by the log output.
	DefaultLogFormat = ""

	// DefaultLogLevel is the default value for log level.
	DefaultLogLevel = "info"

	// DefaultRotateLogs is the default value for whether to enable the built-in
	// log rotation.
	DefaultRotateLogs = true

	// KeyColor is the config key for the value that enforces colors in output.
	KeyColor = "color"

	// KeyConfigFile is the config key for the config file value.
	KeyConfigFile = "config-file"

	// KeyDirectory is the config key for the base directory value.
	KeyDirectory = "directory"

	// KeyLogFile is the config key for the log file path if log destination is
	// set to a file.
	KeyLogFile = "log-file"

	// KeyLogFormat is the config key for the log format value.
	KeyLogFormat = "log-format"

	// KeyLogLevel is the config key for the log level value.
	KeyLogLevel = "log-level"

	// KeyLogOutput is the config key for the log output value. If it is set to
	// `file`, the `log-file` must also be set.
	KeyLogOutput = "log-output"

	// KeyRotateLogs is the config key for the log rotation value.
	KeyRotateLogs = "rotate-logs"

	ValueLogFormatJSON = "json"
	ValueLogFormatText = "text"

	ValueLogOutputFile   = "file"
	ValueLogOutputNone   = "none"
	ValueLogOutputStderr = "stderr"
	ValueLogOutputStdout = "stdout"
)

var (
	// DefaultLogFile is the name for the default file for logging output.
	//
	//nolint:gochecknoglobals // this value is shared and use like a constant
	DefaultLogFile = strings.ToLower(constants.Name) + ".log"

	// LogOutputValueNoneAliases contains the aliases to set as `log-output` in
	// order to achieve the disabling of the logging.
	//
	//nolint:gochecknoglobals // this value is shared and use like a constant
	LogOutputValueNoneAliases = []string{
		"disable",
		"disabled",
		"nil",
		"null",
		"/dev/null",
	}
)
