// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package version

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/spf13/cobra"
)

func Template(v string) string {
	return versionString(v) + "\n"
}

func NewCommand(v string) *cobra.Command {
	s := versionString(v)

	return &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:   constants.VersionCommandName,
		Short: "Print the version information of " + constants.Name,
		Annotations: map[string]string{
			"cmd_fast_init": "true",
		},
		Run: func(_ *cobra.Command, _ []string) {
			fmt.Fprintln(os.Stdout, s)
		},
		SilenceErrors: true,
	}
}

func NewDocCommand(v string) *cobra.Command {
	return NewCommand(v)
}

func versionString(v string) string {
	s := "build"

	if semver.IsValid(v) {
		s = "version"
	}

	return strings.ToLower(constants.Name) + " " + s + " " + v + " " + runtime.GOOS + "/" + runtime.GOARCH
}
