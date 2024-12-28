package semver

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
	"unicode"
)

// errInvalidVersion is the error returned by the version parsing functions when
// they encounter invalid version string.
//
// TODO: Maybe implement different errors for the different cases.
var errInvalidVersion = errors.New("invalid semantic version")

type buildIdentifiers []string

// A Version is a parsed instance of a version number that adheres to the
// semantic versioning 2.0.0.
type Version struct {
	Major      int
	Minor      int
	Patch      int
	Prerelease Prerelease
	Build      buildIdentifiers
	rawStr     string
}

func (v Version) String() string {
	var sb strings.Builder

	sb.WriteString(strconv.Itoa(v.Major))
	sb.WriteString(".")
	sb.WriteString(strconv.Itoa(v.Minor))
	sb.WriteString(".")
	sb.WriteString(strconv.Itoa(v.Patch))

	if len(v.Prerelease.identifiers) > 0 {
		sb.WriteString("-")
		sb.WriteString(v.Prerelease.String())
	}

	return sb.String()
}

// IsValid reports whether s is a valid semantic version string.
func IsValid(s string) bool {
	if _, err := Parse(s); err != nil {
		return false
	}

	return true
}

func countDigits(i int) int {
	if i == 0 {
		return 1
	}

	count := 0

	for i != 0 {
		i /= 10
		count++
	}

	return count
}

func Parse(ver string) (Version, error) {
	if ver == "" {
		return Version{}, fmt.Errorf("empty string: %w", errInvalidVersion)
	}

	pos := 0

	prefix, err := parsePrefix(ver)
	if err != nil {
		return Version{}, fmt.Errorf("failed to parse the version prefix: %w", err)
	}

	pos += len(prefix)

	major, err := parseNextInt(ver[pos:])
	if err != nil {
		return Version{}, fmt.Errorf("failed to parse the major version: %w", err)
	}

	pos += countDigits(major)
	if pos >= len(ver) || ver[pos] != '.' {
		return Version{}, fmt.Errorf("no dot after the major version: %w", errInvalidVersion)
	}

	pos++

	minor, err := parseNextInt(ver[pos:])
	if err != nil {
		return Version{}, fmt.Errorf("failed to parse the minor version: %w", err)
	}

	pos += countDigits(minor)
	if pos >= len(ver) || ver[pos] != '.' {
		return Version{}, fmt.Errorf("no dot after the minor version: %w", errInvalidVersion)
	}

	pos++

	patch, err := parseNextInt(ver[pos:])
	if err != nil {
		return Version{}, fmt.Errorf("failed to parse the patch version: %w", err)
	}

	var prereleaseIdentifiers []prereleaseIdentifier

	pos += countDigits(patch)

	if pos < len(ver) && ver[pos] == '-' {
		// The hyphen is not passed to the parser.
		pos++

		prereleaseIdentifiers, err = parsePrereleaseIdentifiers(ver[pos:])
		if err != nil {
			return Version{}, fmt.Errorf("failed to parse the pre-release identifiers: %w", err)
		}

		// Move the position by the number of dots in the pre-release.
		pos += len(prereleaseIdentifiers) - 1

		for _, v := range prereleaseIdentifiers {
			pos += v.Len()
		}
	}

	var build buildIdentifiers

	if pos < len(ver) && ver[pos] == '+' {
		// Move past the '+'.
		pos++

		build, err = parseBuild(ver[pos:])
		if err != nil {
			return Version{}, fmt.Errorf("failed to parse the build identifiers: %w", err)
		}
	}

	return Version{
		Major:      major,
		Minor:      minor,
		Patch:      patch,
		Prerelease: Prerelease{identifiers: prereleaseIdentifiers},
		Build:      build,
		rawStr:     ver,
	}, nil
}

func isAlphanumericIdentifier(c rune) bool {
	return ('A' <= c && c <= 'Z') || ('a' <= c && c <= 'z') || unicode.IsDigit(c) || c == '-'
}

func isPrereleaseSeparator(c rune) bool {
	return c == '.' || c == '+'
}

func parseBuild(s string) ([]string, error) {
	if s == "" {
		return nil, fmt.Errorf("cannot parse empty string as a build: %w", errInvalidVersion)
	}

	result := strings.Split(s, ".")
	for _, v := range result {
		if s == "" {
			return nil, fmt.Errorf("empty string as a dot-separated build identifier: %w", errInvalidVersion)
		}

		if strings.ContainsFunc(v, func(r rune) bool { return !isAlphanumericIdentifier(r) }) {
			return nil, fmt.Errorf("invalid rune in the build identifier %q: %w", v, errInvalidVersion)
		}
	}

	return result, nil
}

// parseNextInt parses the next integer from the given string. The string should
// be a version string or the next part to parse from a version string adhering
// to the semantic versioning. The first return value is the parsed interger, or
// -1 if the parsing fails. The second return value is an error or nil.
func parseNextInt(s string) (int, error) {
	if s == "" {
		return -1, fmt.Errorf("cannot parse empty string as int: %w", errInvalidVersion)
	}

	if !unicode.IsDigit(rune(s[0])) {
		return -1, fmt.Errorf("first character is not a digit: %w", errInvalidVersion)
	}

	i := 1
	for i < len(s) && unicode.IsDigit(rune(s[i])) {
		i++
	}

	// Check that the number has no leading zeros.
	if s[0] == '0' && i != 1 {
		return -1, fmt.Errorf("the number has a leading zero: %w", errInvalidVersion)
	}

	n, err := strconv.Atoi(s[:i])
	if err != nil {
		return -1, fmt.Errorf("failed to convert the string %s to integer: %w", s[:i], err)
	}

	return n, nil
}

// parsePrefix parses the possible prefixes for the version string. The program
// allows using 'reginald', 'reggie', or 'v' as a prefix in the version string.
func parsePrefix(s string) (string, error) {
	if s == "" {
		return "", fmt.Errorf("empty string: %w", errInvalidVersion)
	}

	i := strings.IndexFunc(s, unicode.IsDigit)
	if i == -1 {
		return "", fmt.Errorf("version string %q has no digits after the possible prefix: %w", s, errInvalidVersion)
	}

	if i == 0 {
		return "", nil
	}

	prefix := s[:i]
	if prefix != "reginald" && prefix != "reggie" && prefix != "v" {
		return "", fmt.Errorf("invalid prefix %q: %w", prefix, errInvalidVersion)
	}

	return prefix, nil
}

func parsePrereleaseIdentifiers(s string) ([]prereleaseIdentifier, error) {
	if s == "" {
		return nil, fmt.Errorf("empty string: %w", errInvalidVersion)
	}

	var builder strings.Builder

	resultLen := strings.Count(s, ".") + 1
	if i := strings.IndexRune(s, '+'); i != -1 {
		resultLen -= strings.Count(s[i:], ".")
	}

	result := make([]prereleaseIdentifier, resultLen)

	i := 0

	for j := range len(s) {
		char := s[j]
		if !isPrereleaseSeparator(rune(char)) {
			builder.WriteByte(char)
		}

		if isPrereleaseSeparator(rune(char)) || j == len(s)-1 {
			current := builder.String()

			isAlphanum := strings.ContainsFunc(current, func(r rune) bool { return !unicode.IsDigit(r) })

			switch {
			case isAlphanum:
				result[i] = alphanumericIdentifier{current}
			case current == "0":
				result[i] = numericIdentifier{0}
			case current[0] != '0':
				num, err := strconv.Atoi(current)
				if err != nil {
					return nil, fmt.Errorf("failed to convert pre-release identifier to integer: %w", err)
				}

				result[i] = numericIdentifier{num}
			default:
				return nil, fmt.Errorf("invalid pre-release identifier %q: %w", current, errInvalidVersion)
			}

			i++

			if char == '+' {
				break
			}

			builder.Reset()
		}

		if !isAlphanumericIdentifier(rune(char)) && char != '.' {
			return nil, fmt.Errorf("invalid pre-release identifier %q: %w", char, errInvalidVersion)
		}
	}

	return result, nil
}
