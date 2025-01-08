// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package logging

import (
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
)

type Config struct {
	File     string `mapstructure:"file"`
	Format   Format `mapstructure:"format"`
	Level    Level  `mapstructure:"level"`
	Output   Output `mapstructure:"output"`
	Rotate   bool   `mapstructure:"rotate"`
	UseColor bool
}

const (
	// DefaultFormat is the initial default value for the `log-format` value.
	// The default is later determined by the log output.
	DefaultFormat = FormatJSON

	// DefaultLevel is the default config value for the logging level.
	DefaultLevel = LevelInfo

	// DefaultOutput is the default config value for the logging output.
	DefaultOutput = OutputFile

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

	// KeyOutput is the config key for the log output value. If it is set to
	// `file`, the `log-file` must also be set.
	KeyOutput = "log.output"

	// KeyRotate is the config key for the log rotation value.
	KeyRotate = "log.rotate"

	// KeyStderr is the config key for settings the logging output to stderr.
	KeyStderr = "log.stderr"

	// KeyStdout is the config key for settings the logging output to stdout.
	KeyStdout = "log.stdout"

	// All of the aliases for the boolean disabling the logging.
	KeyNone     = "log.none"
	KeyNil      = "log.nil"
	KeyNull     = "log.null"
	KeyDisable  = "log.disable"
	KeyDisabled = "log.disabled"
)

var (
	// DefaultFile is the name for the default file for logging output.
	//
	//nolint:gochecknoglobals // Used like a constant.
	DefaultFile = strings.ToLower(constants.Name) + ".log"

	// AllOutputKeys contains all of the possible keys that set the logging
	// output.
	//
	//nolint:gochecknoglobals // Used like a constant.
	AllOutputKeys = []string{
		KeyOutput,
		KeyFile,
		KeyStderr,
		KeyStdout,
		KeyNone,
		KeyNil,
		KeyNull,
		KeyDisable,
		KeyDisabled,
	}
)
