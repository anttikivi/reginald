package main

import (
	"context"
	_ "embed"
	"fmt"
	"os"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/build"
	"github.com/anttikivi/reginald/internal/command"
	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/spf13/viper"
)

func run() int {
	defer logging.HandlePanic()

	// Do this first to avoid having an `init` function in the package.
	build.Init()

	buildVersion := build.Version

	// The parsed version string.
	var v string

	if semver.IsValid(buildVersion) {
		v = semver.MustParse(buildVersion).String()
	} else {
		v = buildVersion
	}

	vpr := viper.New()

	cmd, err := command.New(vpr, v)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)

		return constants.ExitError
	}

	ctx := context.WithValue(context.Background(), config.ViperContextKey, vpr)

	if err := cmd.ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, err)

		return constants.ExitError
	}

	return constants.ExitSuccess
}

func main() {
	os.Exit(run())
}
