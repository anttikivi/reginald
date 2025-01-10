// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package logging

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"

	"github.com/anttikivi/reginald/internal/exit"
	"gopkg.in/natefinch/lumberjack.v2"
)

type NullHandler struct{}

const (
	DefaultTimeFormat                      = "2006-01-02T15:04:05.000-07:00"
	DefaultDecoratedTimeFormat             = "2006-01-02 15:04:05"
	DefaultJSONTimeFormat                  = "2006-01-02T15:04:05.000000-07:00"
	defaultFilePerm            os.FileMode = 0o644
)

const (
	defaultMaxSize    = 10
	defaultMaxBackups = 5
	defaultMaxAge     = 28
)

var (
	errInvalidOutput = errors.New("invalid log output")
	errInvalidFormat = errors.New("invalid log format")
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

// FastInit skip the normal logger initialization and defaults to using
// [NullHandler] instead. Some commands (like `version`) don't require logging
// or are better off running fast without parsing the config, so the parsing is
// skipped and null logging is used instead.
func FastInit() {
	logger := slog.New(NullHandler{})
	slog.SetDefault(logger)
}

// Handler creates an slog.Handler for the given options.
// If the given options do not result in a valid handler, returns an error.
func Handler(w io.Writer, cfg *Config) (slog.Handler, error) {
	if w == io.Discard || cfg.Output == OutputNone || cfg.Level == LevelOff {
		return NullHandler{}, nil
	}

	timeFormat := DefaultJSONTimeFormat
	if cfg.Format == FormatText {
		timeFormat = DefaultDecoratedTimeFormat
	}

	opts := slog.HandlerOptions{ //nolint:exhaustruct // We want to use the default values.
		Level: slog.Level(cfg.Level),
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			if a.Key == slog.TimeKey {
				return slog.String(slog.TimeKey, a.Value.Time().Format(timeFormat))
			}

			return a
		},
	}

	switch cfg.Format {
	case FormatJSON:
		return slog.NewJSONHandler(w, &opts), nil
	case FormatText:
		return slog.NewTextHandler(w, &opts), nil
	default:
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("%w: %v", errInvalidFormat, cfg.Format))
	}
}

func Init(cfg *Config) error {
	// Create the correct writer for the logs.
	logWriter, err := Writer(cfg.Output, cfg.File, cfg.Rotate)
	if err != nil {
		return fmt.Errorf("failed to get the log writer: %w", err)
	}

	logHandler, err := Handler(logWriter, cfg)
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

// Writer returns the correct writer for the specified logger destination.
// The filename file must be supplied if the destination dest is set to file.
// If the destination is a file, parameter rotate controls whether Reginald
// should take care of rotating the logs.
func Writer(out Output, file string, rotate bool) (io.Writer, error) {
	switch out {
	case OutputStderr:
		return os.Stderr, nil
	case OutputStdout:
		return os.Stdout, nil
	case OutputNone:
		return io.Discard, nil
	case OutputFile:
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
				return nil, exit.New(exit.Failure, fmt.Errorf("failed to open log file at %v: %w", file, err))
			}

			return fw, nil
		}
	default:
		return nil, exit.New(exit.InvalidConfig, fmt.Errorf("%w: %s", errInvalidOutput, out))
	}
}
