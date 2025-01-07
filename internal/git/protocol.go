package git

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Protocol is a protocol that the boostrap command can use to clone the remote
// repository.
//
//nolint:recvcheck // Unmarshaling functions expect a pointer but the [fmt.Stringer] implementation expects a value.
type Protocol int

// Possible protocols to use. These values are parsed from the configuration
// using the unmarshaling methods for [Protocol].
const (
	SSH Protocol = iota
	HTTPS
)

var ErrInvalidProtocol = errors.New("invalid protocol")

// MarshalJSON implements [encoding/json.Marshaler] by quoting the output of
// [Protocol.String].
func (p Protocol) MarshalJSON() ([]byte, error) {
	// AppendQuote is sufficient for JSON-encoding all Protocol strings. They
	// don't contain any runes that would produce invalid JSON when escaped.
	return strconv.AppendQuote(nil, p.String()), nil
}

// MarshalText implements [encoding.TextMarshaler] by calling [Protocol.String].
func (p Protocol) MarshalText() ([]byte, error) {
	if p != SSH && p != HTTPS {
		return nil, fmt.Errorf("%w: %d", ErrInvalidProtocol, p)
	}

	return []byte(p.String()), nil
}

// String returns the name of the protocol.
func (p Protocol) String() string {
	switch p {
	case SSH:
		return "ssh"
	case HTTPS:
		return "https"
	default:
		return "invalid"
	}
}

// UnmarshalJSON implements [encoding/json.Unmarshaler]. It accepts any string
// produced by [Protocol.MarshalJSON], ignoring case.
func (p *Protocol) UnmarshalJSON(data []byte) error {
	s, err := strconv.Unquote(string(data))
	if err != nil {
		return fmt.Errorf("failed to unquote protocol JSON value: %s: %w", string(data), err)
	}

	return p.unmarshal(s)
}

// UnmarshalText implements [encoding.TextUnmarshaler]. It accepts any string
// produced by [Protocol.MarshalText], ignoring case.
func (p *Protocol) UnmarshalText(text []byte) error {
	return p.unmarshal(string(text))
}

// unmarshal parses a string representing a [Protocol] for unmarshaling the
// value.
func (p *Protocol) unmarshal(s string) error {
	switch strings.ToLower(s) {
	case "ssh":
		*p = SSH
	case "https":
		*p = HTTPS
	default:
		return fmt.Errorf("%w: %s", ErrInvalidProtocol, s)
	}

	return nil
}
