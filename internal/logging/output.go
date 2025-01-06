package logging

import (
	"fmt"
	"slices"
	"strconv"
	"strings"
)

// Output is the output for logging.
//
//nolint:recvcheck,lll // Unmarshaling functions expect a pointer receiver but the [fmt.Stringer] implementation expects a value receiver.
type Output int

const (
	// OutputFile is the value for the logging output when the logs are written
	// to a file.
	OutputFile Output = iota

	// OutputStderr is the value for the logging output when the logs are
	// written to [os.Stderr].
	OutputStderr

	// OutputStdout is the value for the logging output when the logs are
	// written to [os.Stdout].
	OutputStdout

	// OutputNone is the value for the logging output when the logging is
	// disabled.
	OutputNone
)

// OutputValueNoneAliases contains the aliases that [Output] accepts instead of
// "none" in the config.
//
//nolint:gochecknoglobals // This value is used like a constant.
var OutputValueNoneAliases = []string{"disable", "disabled", "nil", "null", "/dev/null"}

// AllOutputValues contains all of the possible values for the log output besides
// a filename.
//
//nolint:gochecknoglobals // This value is used like a constant.
var AllOutputValues = []string{
	"file",
	"stderr",
	"stdout",
	"none",
	"disable",
	"disabled",
	"nil",
	"null",
	"/dev/null",
}

// MarshalJSON implements [encoding/json.Marshaler] by quoting the output of
// [Output.String].
func (o Output) MarshalJSON() ([]byte, error) {
	// AppendQuote is sufficient for JSON-encoding all Output strings. They
	// don't contain any runes that would produce invalid JSON when escaped.
	return strconv.AppendQuote(nil, o.String()), nil
}

// MarshalText implements [encoding.TextMarshaler] by calling [Output.String].
func (o Output) MarshalText() ([]byte, error) {
	if o != OutputFile && o != OutputStderr && o != OutputStdout && o != OutputNone {
		return nil, fmt.Errorf("%w: %d", errInvalidOutput, o)
	}

	return []byte(o.String()), nil
}

// String returns the name of the output.
func (o Output) String() string {
	switch o {
	case OutputFile:
		return "file"
	case OutputStderr:
		return "stderr"
	case OutputStdout:
		return "stdout"
	case OutputNone:
		return "none"
	default:
		return "invalid"
	}
}

// UnmarshalJSON implements [encoding/json.Unmarshaler]. It accepts any string
// produced by [Output.MarshalJSON], ignoring case.
func (o *Output) UnmarshalJSON(data []byte) error {
	s, err := strconv.Unquote(string(data))
	if err != nil {
		return fmt.Errorf("failed to unquote log output JSON value: %s: %w", string(data), err)
	}

	return o.unmarshal(s)
}

// UnmarshalText implements [encoding.TextUnmarshaler]. It accepts any string
// produced by [Output.MarshalText], ignoring case.
func (o *Output) UnmarshalText(text []byte) error {
	return o.unmarshal(string(text))
}

// unmarshal parses a string representing a [Output] for unmarshaling the value.
func (o *Output) unmarshal(s string) error {
	s = strings.ToLower(s)
	if slices.Contains(OutputValueNoneAliases, s) {
		*o = OutputNone

		return nil
	}

	switch s {
	case "file":
		*o = OutputFile
	case "stderr":
		*o = OutputStderr
	case "stdout":
		*o = OutputStdout
	case "none":
		*o = OutputNone
	default:
		return fmt.Errorf("%w: %s", errInvalidOutput, s)
	}

	return nil
}
