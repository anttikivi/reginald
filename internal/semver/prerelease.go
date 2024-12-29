package semver

import (
	"fmt"
	"strconv"
	"strings"
)

// A Prerelease holds the pre-release identifiers of a version.
type Prerelease struct {
	identifiers []prereleaseIdentifier
}

// A prereleaseIdentifier is a single pre-release identifier separated by dots.
type prereleaseIdentifier interface {
	// Len returns the length of the pre-release identifier in characters.
	Len() int

	// String returns the string representation of the identifier.
	String() string

	// Value returns the Value for the identifier. If the identifier is a
	// numeric one, the Value is returned using the first return Value and the
	// second return Value is an empty string. If the identifier is an
	// alphanumeric identifier, the Value is returned using the second return
	// Value and the first return Value is -1.
	Value() (n int, s string)
}

type numericIdentifier struct {
	v int
}

type alphanumericIdentifier struct {
	v string
}

func (p Prerelease) String() string {
	var sb strings.Builder

	if len(p.identifiers) > 0 {
		for _, ident := range p.identifiers {
			i, s := ident.Value()

			switch {
			case i >= 0 && s == "":
				sb.WriteString(strconv.Itoa(i))
			case i == -1 && s != "":
				sb.WriteString(s)
			default:
				// TODO: Try not to panic, but we should never get here.
				panic(fmt.Sprintf("invalid pre-release identifier options: %d and %s", i, s))
			}

			sb.WriteRune('.')
		}
	} else {
		return ""
	}

	s := sb.String()

	return s[:len(s)-1]
}

func (i numericIdentifier) Len() int {
	return countDigits(i.v)
}

func (i numericIdentifier) String() string {
	return strconv.Itoa(i.v)
}

func (i numericIdentifier) Value() (int, string) {
	return i.v, ""
}

func (i alphanumericIdentifier) Len() int {
	return len(i.v)
}

func (i alphanumericIdentifier) String() string {
	return i.v
}

func (i alphanumericIdentifier) Value() (int, string) {
	return -1, i.v
}
