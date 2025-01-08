// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package logging

import (
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
)

// Level is the importance or severity of a log event. The higher the level,
// the more important or severe the event.
//
// Level can directly be converted to [slog.Level] for use in the underlying
// logger.
//
// A custom type is implemented in order to support the custom values the
// program's configuration accepts.
//
//nolint:recvcheck,lll // Unmarshaling functions expect a pointer receiver but the [fmt.Stringer] implementation expects a value receiver.
type Level slog.Level

// Names for common levels.
//
// Level numbers match the levels for [slog.Level].
const (
	LevelDebug Level = Level(slog.LevelDebug)
	LevelInfo  Level = Level(slog.LevelInfo)
	LevelWarn  Level = Level(slog.LevelWarn)
	LevelError Level = Level(slog.LevelError)
	LevelOff   Level = 16
)

var errUnknownLevel = errors.New("unknown log level")

// MarshalJSON implements [encoding/json.Marshaler] by quoting the output of
// [Level.String].
func (l Level) MarshalJSON() ([]byte, error) {
	// AppendQuote is sufficient for JSON-encoding all Level strings. They
	// don't contain any runes that would produce invalid JSON when escaped.
	return strconv.AppendQuote(nil, l.String()), nil
}

// MarshalText implements [encoding.TextMarshaler] by calling [Level.String].
func (l Level) MarshalText() ([]byte, error) {
	return []byte(l.String()), nil
}

// String returns a name for the level. If the level has a name, then that name
// in uppercase is returned. If the level is between named values, then an
// integer is appended to the uppercased name. Examples:
//
//	LevelWarn.String() => "WARN"
//	(LevelInfo+2).String() => "INFO+2"
func (l Level) String() string {
	str := func(base string, val Level) string {
		if val == 0 {
			return base
		}

		return fmt.Sprintf("%s%+d", base, val)
	}

	switch {
	case l < LevelInfo:
		return str("DEBUG", l-LevelDebug)
	case l < LevelWarn:
		return str("INFO", l-LevelInfo)
	case l < LevelError:
		return str("WARN", l-LevelWarn)
	case l < LevelOff:
		return str("ERROR", l-LevelError)
	default:
		return str("OFF", l-LevelOff)
	}
}

// UnmarshalJSON implements [encoding/json.Unmarshaler]. It accepts any string
// produced by [Level.MarshalJSON], ignoring case.
func (l *Level) UnmarshalJSON(data []byte) error {
	s, err := strconv.Unquote(string(data))
	if err != nil {
		return fmt.Errorf("failed to unquote log level JSON value: %s: %w", string(data), err)
	}

	return l.unmarshal(s)
}

// UnmarshalText implements [encoding.TextUnmarshaler]. It accepts any string
// produced by [Level.MarshalText], ignoring case.
func (l *Level) UnmarshalText(text []byte) error {
	return l.unmarshal(string(text))
}

// unmarshal parses a string representing a [Level] for unmarshaling the value.
func (l *Level) unmarshal(s string) error {
	name := s
	offset := 0

	if i := strings.IndexAny(s, "+-"); i >= 0 {
		var err error

		name = s[:i]

		offset, err = strconv.Atoi(s[i:])
		if err != nil {
			return fmt.Errorf("level string %q: %w", s, err)
		}
	}

	switch strings.ToUpper(name) {
	case "DEBUG":
		*l = LevelDebug
	case "INFO":
		*l = LevelInfo
	case "WARN":
		*l = LevelWarn
	case "ERROR":
		*l = LevelError
	case "OFF":
		*l = LevelOff
	default:
		return fmt.Errorf("level string %q: %w", s, errUnknownLevel)
	}

	*l += Level(offset)

	return nil
}
