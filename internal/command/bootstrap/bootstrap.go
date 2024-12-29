package bootstrap

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

func NewCommand() *cobra.Command {
	return &cobra.Command{ //nolint:exhaustruct
		Use:     "bootstrap",
		Aliases: []string{"init", "initialise", "initialize"},
		Short:   "Ask Reginald to bootstrap your environment",
		Long: `Bootstrap clones the specified dotfiles directory and runs the initial installation.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory
already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`,
		RunE: run,
	}
}

func run(_ *cobra.Command, _ []string) error {
	fmt.Fprintln(os.Stderr, "Bootstrap")

	return nil
}
