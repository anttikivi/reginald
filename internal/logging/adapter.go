// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

//nolint:ireturn // Implements interface.
package logging

import (
	"io"
	"log"
	"log/slog"
	"strings"

	"github.com/hashicorp/go-hclog"
)

// SlogAdapter is adapter to use an [slog.Logger] as an hclog.Logger. It is used
// by the plugin system as it uses hclog while Reginald uses the standard
// library slog.
type SlogAdapter struct {
	logger      *slog.Logger
	level       slog.Level
	name        string
	impliedArgs []any
}

// hclogLevelStrings contains level strings that might be included in the
// messages passed from the server. They are used for fixing the levels of some
// messages manually.
//
//nolint:gochecknoglobals // Used like a constant.
var hclogLevelStrings = map[string]hclog.Level{
	"TRACE": hclog.Trace,
	"DEBUG": hclog.Debug,
	"INFO":  hclog.Info,
	"WARN":  hclog.Warn,
	"ERR":   hclog.Error,
}

func NewSlogAdapter(logger *slog.Logger, level slog.Level, name string) *SlogAdapter {
	return &SlogAdapter{
		logger:      logger,
		level:       level,
		name:        name,
		impliedArgs: nil,
	}
}

func (l *SlogAdapter) Log(level hclog.Level, msg string, args ...any) {
	// Check for prefixes in the message that contain a level set by [hclog]. It
	// is simpler to do this here instead of ReplaceAttr in [slog.HandlerOptions].
	for k, v := range hclogLevelStrings {
		prefix := "[" + k + "]"
		if strings.HasPrefix(msg, prefix) {
			l.Log(v, strings.TrimPrefix(msg, prefix+" "), args...)

			return
		}
	}

	switch level {
	case hclog.Trace, hclog.Debug:
		l.logger.Debug(msg, args...)
	case hclog.Info:
		l.logger.Info(msg, args...)
	case hclog.Warn:
		l.logger.Warn(msg, args...)
	case hclog.Error:
		l.logger.Error(msg, args...)
	case hclog.Off:
	case hclog.NoLevel:
		l.logger.Info(msg, args...)
	default:
		l.logger.Info(msg, args...)
	}
}

func (l *SlogAdapter) Trace(msg string, args ...any) {
	l.Log(hclog.Trace, msg, args...)
}

func (l *SlogAdapter) Debug(msg string, args ...any) {
	l.Log(hclog.Debug, msg, args...)
}

func (l *SlogAdapter) Info(msg string, args ...any) {
	l.Log(hclog.Info, msg, args...)
}

func (l *SlogAdapter) Warn(msg string, args ...any) {
	l.Log(hclog.Warn, msg, args...)
}

func (l *SlogAdapter) Error(msg string, args ...any) {
	l.Log(hclog.Error, msg, args...)
}

func (l *SlogAdapter) IsTrace() bool {
	return l.level <= slog.LevelDebug
}

func (l *SlogAdapter) IsDebug() bool {
	return l.level <= slog.LevelDebug
}

func (l *SlogAdapter) IsInfo() bool {
	return l.level <= slog.LevelInfo
}

func (l *SlogAdapter) IsWarn() bool {
	return l.level <= slog.LevelWarn
}

func (l *SlogAdapter) IsError() bool {
	return l.level <= slog.LevelError
}

func (l *SlogAdapter) ImpliedArgs() []any {
	return l.impliedArgs
}

func (l *SlogAdapter) With(args ...any) hclog.Logger {
	c := cloneLogger(l.logger)
	impliedArgs := make([]any, 0)
	impliedArgs = append(impliedArgs, l.impliedArgs...)
	impliedArgs = append(impliedArgs, args...)

	return &SlogAdapter{
		logger:      c.With(impliedArgs...),
		level:       l.level,
		name:        l.name,
		impliedArgs: impliedArgs,
	}
}

func (l *SlogAdapter) Name() string {
	return l.name
}

func (l *SlogAdapter) Named(name string) hclog.Logger {
	c := cloneLogger(l.logger)

	return &SlogAdapter{
		logger:      c,
		name:        l.name + name,
		level:       l.level,
		impliedArgs: l.impliedArgs,
	}
}

func (l *SlogAdapter) ResetNamed(name string) hclog.Logger {
	c := cloneLogger(l.logger)

	return &SlogAdapter{
		logger:      c,
		name:        name,
		level:       l.level,
		impliedArgs: l.impliedArgs,
	}
}

func (l *SlogAdapter) SetLevel(_ hclog.Level) {
	// TODO: Should this have an implementation.
}

func (l *SlogAdapter) GetLevel() hclog.Level {
	switch l.level {
	case slog.LevelDebug:
		return hclog.Debug
	case slog.LevelInfo:
		return hclog.Info
	case slog.LevelWarn:
		return hclog.Warn
	case slog.LevelError:
		return hclog.Error
	default:
		return hclog.Off
	}
}

func (l *SlogAdapter) StandardLogger(_ *hclog.StandardLoggerOptions) *log.Logger {
	// TODO: This is probably not the best implementation.
	return slog.NewLogLogger(l.logger.Handler(), l.level)
}

func (l *SlogAdapter) StandardWriter(opts *hclog.StandardLoggerOptions) io.Writer {
	// TODO: This is probably not the best implementation.
	return l.StandardLogger(opts).Writer()
}

func cloneLogger(l *slog.Logger) *slog.Logger {
	c := *l

	return &c
}
