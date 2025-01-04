package logging

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"

	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/spf13/cobra"
	"gopkg.in/natefinch/lumberjack.v2"
)

type NullHandler struct{}

const (
	defaultFilePerm os.FileMode = 0o644
	LevelOff        slog.Level  = 12
)

const (
	defaultMaxSize    = 10
	defaultMaxBackups = 5
	defaultMaxAge     = 28
)

var (
	errInvalidOutput = errors.New("invalid log output")
	errInvalidFormat = errors.New("invalid log format")
	errInvalidLevel  = errors.New("invalid log level")
)

func (h NullHandler) Enabled(_ context.Context, _ slog.Level) bool {
	return false
}

//nolint:gocritic // hugeParam disabled as interface implementation requires for the correct type
func (h NullHandler) Handle(_ context.Context, _ slog.Record) error {
	return nil
}

func (h NullHandler) WithAttrs(_ []slog.Attr) slog.Handler {
	return h
}

func (h NullHandler) WithGroup(_ string) slog.Handler {
	return h
}

// CanFastInit reports whether the given command can skip parsing the
// configuration for logging and instead default to using [NullHandler].
func CanFastInit(cmd *cobra.Command) bool {
	return cmd == nil || cmd.Name() == version.CmdName
}

// FastInit skip the normal logger initialization and defaults to using
// [NullHandler] instead. Some commands (like `version`) don't require logging
// or are better of running fast without parsing the config, so the parsing is
// skipped and null logging is used instead.
func FastInit(cmd *cobra.Command) {
	if CanFastInit(cmd) {
		logger := slog.New(NullHandler{})
		slog.SetDefault(logger)
	}
}

// Handler creates an slog.Handler for the given options.
// If the given options do not result in a valid handler, returns an error.
func Handler(w io.Writer, format string, level slog.Level) (slog.Handler, error) {
	if w == io.Discard {
		return NullHandler{}, nil
	}

	switch format {
	case ValueFormatJSON:
		//nolint:exhaustruct // we want to use the default values
		return slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level}), nil
	case ValueFormatText:
		//nolint:exhaustruct // we want to use the default values
		return slog.NewTextHandler(w, &slog.HandlerOptions{Level: level}), nil
	default:
		return nil, fmt.Errorf("%w: %s", errInvalidFormat, format)
	}
}

func Init(cfg *Config) error {
	// Create the correct writer for the logs.
	logWriter, err := Writer(cfg.Output, cfg.File, cfg.Rotate)
	if err != nil {
		return fmt.Errorf("failed to get the log writer: %w", err)
	}

	logHandler, err := Handler(logWriter, cfg.Format, cfg.Level)
	if err != nil {
		return fmt.Errorf("failed to create the log handler: %w", err)
	}

	logger := slog.New(logHandler)

	slog.SetDefault(logger)
	slog.Info(
		"Logging initialized",
		"output",
		cfg.Output,
		"format",
		cfg.Format,
		"level",
		cfg.Level,
		"file",
		cfg.File,
		"rotate",
		cfg.Rotate,
	)

	return nil
}

// Level returns the slog.Level that corresponds to the given string.
// If the string is not a valid log level, returns an error.
func Level(l string) (slog.Level, error) {
	switch strings.ToLower(l) {
	case "debug":
		return slog.LevelDebug, nil
	case "info":
		return slog.LevelInfo, nil
	case "warn", "warning":
		return slog.LevelWarn, nil
	case "error", "err":
		return slog.LevelError, nil
	case "off":
		// TODO: Figure out a better value. Logs are disabled anyway.
		return LevelOff, nil
	default:
		return slog.LevelDebug, fmt.Errorf("%w: %v", errInvalidLevel, l)
	}
}

// Writer returns the correct writer for the specified logger destination.
// The filename file must be supplied if the destination dest is set to file.
// If the destination is a file, parameter rotate controls whether Reginald
// should take care of rotating the logs.
func Writer(dest, file string, rotate bool) (io.Writer, error) {
	switch dest {
	case ValueOutputStdout:
		return os.Stdout, nil
	case ValueOutputStderr:
		return os.Stderr, nil
	case ValueOutputNone:
		return io.Discard, nil
	case ValueOutputFile:
		if rotate {
			return &lumberjack.Logger{
				Filename:   file,
				MaxSize:    defaultMaxSize,
				MaxBackups: defaultMaxBackups,
				MaxAge:     defaultMaxAge,
				LocalTime:  true,
				Compress:   true,
			}, nil
		} else {
			fw, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND|os.O_CREATE, defaultFilePerm)
			if err != nil {
				return nil, fmt.Errorf("failed to open log file at %v: %w", file, err)
			}

			return fw, nil
		}
	default:
		return nil, fmt.Errorf("%w: %s", errInvalidOutput, dest)
	}
}
