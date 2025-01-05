package logging

import (
	"log/slog"
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
)

type Config struct {
	File     string     `mapstructure:"file"`
	Format   string     `mapstructure:"format"`
	Level    slog.Level `mapstructure:"level"`
	Output   string     `mapstructure:"output"`
	Plain    bool       `mapstructure:"plain"`
	Rotate   bool       `mapstructure:"rotate"`
	UseColor bool
}

const (
	// DefaultFormat is the initial default value for the `log-format` value.
	// The default is later determined by the log output.
	DefaultFormat = ""

	// DefaultLevel is the default value for log level.
	DefaultLevel slog.Level = slog.LevelInfo

	// DefaultLevelName is the name of the default value for log level.
	DefaultLevelName = "info"

	// DefaultPlain is the default value for whether logs should be printed
	// without decorations to the terminal.
	DefaultPlain = false

	// DefaultRotate is the default value for whether to enable the built-in log
	// rotation.
	DefaultRotate = true

	// KeyFile is the config key for the log file path if log destination is
	// set to a file.
	KeyFile = "log.file"

	// KeyFormat is the config key for the log format value.
	KeyFormat = "log.format"

	// KeyLevel is the config key for the log level value.
	KeyLevel = "log.level"

	// KeyLevelName is the config key for the intermediate logging level
	// value.
	KeyLevelName = "log.level-name"

	// KeyOutput is the config key for the log output value. If it is set to
	// `file`, the `log-file` must also be set.
	KeyOutput = "log.output"

	// KeyPlain is the config key for the log to be printed without decorations
	// to terminal if colors are enabled and the logs are output to either
	// stderr or stdout.
	KeyPlain = "log.plain"

	// KeyRotate is the config key for the log rotation value.
	KeyRotate = "log.rotate"

	ValueFormatJSON = "json"
	ValueFormatText = "text"

	ValueOutputFile   = "file"
	ValueOutputNone   = "none"
	ValueOutputStderr = "stderr"
	ValueOutputStdout = "stdout"
)

var (
	// DefaultFile is the name for the default file for logging output.
	//
	//nolint:gochecknoglobals // this value is shared and use like a constant
	DefaultFile = strings.ToLower(constants.Name) + ".log"

	// OutputValueNoneAliases contains the aliases to set as `log-output` in
	// order to achieve the disabling of the logging.
	//
	//nolint:gochecknoglobals // this value is shared and use like a constant
	OutputValueNoneAliases = []string{
		"disable",
		"disabled",
		"nil",
		"null",
		"/dev/null",
	}
)
