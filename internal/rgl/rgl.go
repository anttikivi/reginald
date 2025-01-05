package rgl

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/build"
	"github.com/anttikivi/reginald/internal/command"
	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/spf13/viper"
)

// Run runs Reginald with the standard version number set with the build script.
// The function returns the exit code for the process.
func Run() exit.Code {
	defer exit.HandlePanic()

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
func RunAs(v string) exit.Code {
	defer exit.HandlePanic()

	return run(v)
}

func run(v string) exit.Code {
	if v == "" {
		// TODO: Change to a nicer value.
		v = "INVALID"
	}

	vpr := viper.New()

	cmd, err := command.New(vpr, v)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)

		var exitError *exit.Error
		if errors.As(err, &exitError) {
			return exitError.Code
		}

		return exit.Failure
	}

	ctx := context.WithValue(context.Background(), config.ViperContextKey, vpr)

	if err := cmd.ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)

		var exitError *exit.Error
		if errors.As(err, &exitError) {
			return exitError.Code
		}

		return exit.Failure
	}

	return exit.Success
}
