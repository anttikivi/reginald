// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package reggie

import (
	"errors"
	"fmt"
	"os"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/build"
	"github.com/anttikivi/reginald/internal/cmd/base"
	"github.com/anttikivi/reginald/internal/errutil"
)

// Run runs Reginald with the standard version number set with the build script.
// The function returns the exit code for the process.
func Run() errutil.Code {
	defer errutil.HandlePanic()

	buildVersion := build.Version

	// The parsed version string.
	var v string

	if semver.IsValid(buildVersion) {
		v = semver.MustParse(buildVersion).String()
	} else {
		v = buildVersion
	}

	return run(v)
}

// RunAs runs Reginald with the given version number. This is used by the
// command built with `go build` as it doesn't receive a version from the build
// script. The function returns the exit code for the process.
func RunAs(v string) errutil.Code {
	defer errutil.HandlePanic()

	return run(v)
}

func run(v string) errutil.Code {
	if v == "" {
		// TODO: Change to a nicer value.
		v = "INVALID"
	}

	reggie, err := base.New(v)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)

		var exitError *errutil.Error
		if errors.As(err, &exitError) {
			return exitError.Code()
		}

		return errutil.Failure
	}

	if err := reggie.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "exiting: %v\n", err)

		var exitError *errutil.Error
		if errors.As(err, &exitError) {
			return exitError.Code()
		}

		return errutil.Failure
	}

	return errutil.Success
}
