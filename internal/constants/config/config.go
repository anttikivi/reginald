package config

const (
	// LogDestinationKey is the config key for the log destination value. If it
	// is set to `file`, the `log-file` must also be set.
	LogDestinationKey         = "log-destination"
	LogDestinationValueFile   = "file"
	LogDestinationValueNone   = "none"
	LogDestinationValueStderr = "stderr"
	LogDestinationValueStdout = "stdout"

	// LogFileKey is the config key for the log file path if log destination is
	// set to a file.
	LogFileKey = "log-file"
)

// LogDestinationValueNoneAliases contains the aliases to set as
// `log-destination` in order to achieve the disabling of the logging.
//
//nolint:gochecknoglobals // this value is shared and use like a constant
var LogDestinationValueNoneAliases = []string{
	"disable",
	"disabled",
	"nil",
	"null",
	"/dev/null",
}
