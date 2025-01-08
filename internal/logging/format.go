// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package logging

import (
	"fmt"
	"strconv"
	"strings"
)

// Format is the output format for logging.
//
//nolint:recvcheck,lll // Unmarshaling functions expect a pointer receiver but the [fmt.Stringer] implementation expects a value receiver.
type Format int

const (
	// FormatJSON is the logging format when the logs are output as JSON.
	FormatJSON Format = iota

	// FormatText is the logging format when the logs are output as text.
	FormatText
)

// MarshalJSON implements [encoding/json.Marshaler] by quoting the output of
// [Format.String].
func (f Format) MarshalJSON() ([]byte, error) {
	// AppendQuote is sufficient for JSON-encoding all Format strings. They
	// don't contain any runes that would produce invalid JSON when escaped.
	return strconv.AppendQuote(nil, f.String()), nil
}

// MarshalText implements [encoding.TextMarshaler] by calling [Format.String].
func (f Format) MarshalText() ([]byte, error) {
	if f != FormatJSON && f != FormatText {
		return nil, fmt.Errorf("%w: %d", errInvalidFormat, f)
	}

	return []byte(f.String()), nil
}

// String returns the name of the format.
func (f Format) String() string {
	switch f {
	case FormatJSON:
		return "json"
	case FormatText:
		return "text"
	default:
		return "invalid"
	}
}

// UnmarshalJSON implements [encoding/json.Unmarshaler]. It accepts any string
// produced by [Format.MarshalJSON], ignoring case.
func (f *Format) UnmarshalJSON(data []byte) error {
	s, err := strconv.Unquote(string(data))
	if err != nil {
		return fmt.Errorf("failed to unquote log format JSON value: %s: %w", string(data), err)
	}

	return f.unmarshal(s)
}

// UnmarshalText implements [encoding.TextUnmarshaler]. It accepts any string
// produced by [Format.MarshalText], ignoring case.
func (f *Format) UnmarshalText(text []byte) error {
	return f.unmarshal(string(text))
}

// unmarshal parses a string representing a [Format] for unmarshaling the value.
func (f *Format) unmarshal(s string) error {
	switch strings.ToLower(s) {
	case "json":
		*f = FormatJSON
	case "text":
		*f = FormatText
	default:
		return fmt.Errorf("%w: %s", errInvalidFormat, s)
	}

	return nil
}
