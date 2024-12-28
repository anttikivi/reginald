package main

import (
	_ "embed"
	"fmt"
	"os"
	"strings"

	"github.com/anttikivi/reginald/internal/command"
	"github.com/anttikivi/reginald/internal/semver"
)

// rawVersion is the raw version value read from the VERSION file. It is used
// if buildVersion is not set.
//
//go:embed VERSION
var rawVersion string

// buildVersion is the version set using linker flags build time. It is used to
// over the value embedded from the VERSION file if set.
var buildVersion string //nolint:gochecknoglobals

func main() {
	v := parseVersion()

	cmd, err := command.NewReginaldCommand(v)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(command.ExitError)
	}

	if err := cmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(command.ExitError)
	}
}

// parseVersion parses the program version from the version data set during
// build.
// It panics if the version cannot be parsed as the version string set during
// builds must not be an invalid version.
func parseVersion() semver.Version {
	v, err := semver.Parse(rawVersionString())
	if err != nil {
		panic(fmt.Sprintf("failed to parse the version: %v", err))
	}

	return v
}

// rawVersionString returns the unparsed version string the will be used to
// parse the program version.
func rawVersionString() string {
	s := buildVersion
	if s == "" {
		s = rawVersion
	}

	s = strings.TrimSpace(s)

	return s
}
