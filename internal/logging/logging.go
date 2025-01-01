package logging

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"

	"gopkg.in/natefinch/lumberjack.v2"
)

type NullHandler struct{}

const (
	defaultLogFilePerm os.FileMode = 0o644
	logLevelOff        slog.Level  = 12
)

const (
	defaultLogMaxSize    = 10
	defaultLogMaxBackups = 5
	defaultLogMaxAge     = 28
)

var (
	errInvalidLogDestination = errors.New("invalid log destination")
	errInvalidLogFormat      = errors.New("invalid log format")
	errInvalidLogLevel       = errors.New("invalid log level")
)

func (h NullHandler) Enabled(_ context.Context, _ slog.Level) bool {
	return false
}

func (h NullHandler) Handle(_ context.Context, _ slog.Record) error { //nolint:gocritic,lll // hugeParam disabled as interface implementation requires for the correct type
	return nil
}

func (h NullHandler) WithAttrs(_ []slog.Attr) slog.Handler {
	return h
}

func (h NullHandler) WithGroup(_ string) slog.Handler {
	return h
}

// Handler creates an slog.Handler for the given options.
// If the given options do not result in a valid handler, returns an error.
func Handler(w io.Writer, format string, level slog.Level) (slog.Handler, error) {
	if w == io.Discard {
		return NullHandler{}, nil
	}

	switch format {
	case "json":
		return slog.NewJSONHandler(w, &slog.HandlerOptions{Level: level}), nil //nolint:exhaustruct,lll // we want to use the default values
	case "text":
		return slog.NewTextHandler(w, &slog.HandlerOptions{Level: level}), nil //nolint:exhaustruct,lll // we want to use the default values
	default:
		return nil, fmt.Errorf("%w: %s", errInvalidLogFormat, format)
	}
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
		return logLevelOff, nil
	default:
		return slog.LevelDebug, fmt.Errorf("%w: %v", errInvalidLogLevel, l)
	}
}

// Writer returns the correct writer for the specified logger destination.
// The filename file must be supplied if the destination dest is set to file.
// If the destination is a file, parameter rotate controls whether Reginald
// should take care of rotating the logs.
func Writer(dest, file string, rotate bool) (io.Writer, error) {
	switch dest {
	case "stdout":
		return os.Stdout, nil
	case "stderr":
		return os.Stderr, nil
	case "none":
		return io.Discard, nil
	case "file":
		if rotate {
			return &lumberjack.Logger{
				Filename:   file,
				MaxSize:    defaultLogMaxSize,
				MaxBackups: defaultLogMaxBackups,
				MaxAge:     defaultLogMaxAge,
				LocalTime:  true,
				Compress:   true,
			}, nil
		} else {
			fw, err := os.OpenFile(file, os.O_WRONLY|os.O_APPEND|os.O_CREATE, defaultLogFilePerm)
			if err != nil {
				return nil, fmt.Errorf("failed to open log file at %v: %w", file, err)
			}

			return fw, nil
		}
	default:
		return nil, fmt.Errorf("%w: %s", errInvalidLogDestination, dest)
	}
}
