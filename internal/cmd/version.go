package cmd

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/constants"
)

func printVersion(c *Command) {
	fmt.Fprintln(os.Stdout, versionString(c.Version))
	fmt.Fprintln(os.Stdout, "Copyright (c) 2025 Antti Kivi")
}

func versionString(v string) string {
	s := "build"

	if semver.IsValid(v) {
		s = "version"
	}

	return strings.ToLower(constants.Name) + " " + s + " " + v + " " + runtime.GOOS + "/" + runtime.GOARCH
}
