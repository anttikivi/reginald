package bootstrap

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/spf13/cobra"
)

func NewCommand() *cobra.Command {
	return &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:     "bootstrap",
		Aliases: []string{"init", "initialise", "initialize"},
		Short:   "Ask " + constants.Name + " to bootstrap your environment",
		Long:    strutil.Cap(description(), constants.HelpLineLen),
		RunE:    run,
	}
}

func NewDocsCommand() *cobra.Command {
	return NewCommand()
}

func description() string {
	return `Bootstrap clones the specified dotfiles directory and runs the initial installation.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`
}

func run(_ *cobra.Command, _ []string) error {
	fmt.Fprintln(os.Stderr, "Bootstrap")

	return nil
}
