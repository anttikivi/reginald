package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/build"
	"github.com/anttikivi/reginald/internal/command"
	"github.com/anttikivi/reginald/internal/docs"
	"github.com/spf13/pflag"
)

const defaultDirPerm os.FileMode = 0o755

var errPathNotDefined = errors.New("--path is not set")

func run() error {
	// Do this first to avoid having an `init` function in the package.
	build.Init()

	flags := pflag.NewFlagSet("", pflag.ContinueOnError)
	man := flags.Bool("man", false, "Generate manual pages")
	dir := flags.String("path", "", "Path to the directory where you want to generate the docs to")
	help := flags.BoolP("help", "h", false, "Help about any command")

	if err := flags.Parse(os.Args); err != nil {
		return fmt.Errorf("%w", err)
	}

	if *help {
		fmt.Fprintf(os.Stdout, "Usage of %s:\n\n%s", filepath.Base(os.Args[0]), flags.FlagUsages())

		return nil
	}

	if *dir == "" {
		return fmt.Errorf("error: %w", errPathNotDefined)
	}

	buildVersion := build.Version

	var v string

	if semver.IsValid(buildVersion) {
		v = semver.MustParse(buildVersion).String()
	} else {
		v = buildVersion
	}

	cmd, _ := command.NewDoc(v)
	cmd.InitDefaultHelpCmd()

	if err := os.MkdirAll(*dir, defaultDirPerm); err != nil {
		return fmt.Errorf("%w", err)
	}

	if *man {
		if err := docs.GenerateManTree(cmd, *dir); err != nil {
			return fmt.Errorf("%w", err)
		}
	}

	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
