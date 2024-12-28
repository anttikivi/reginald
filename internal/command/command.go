package command

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

const (
	Name        = "Reginald"
	CommandName = "reginald"
	ExitError   = 1
)

func NewReginaldCommand() *cobra.Command {
	cmd := &cobra.Command{ //nolint:exhaustruct
		Use:   CommandName + " <command> [flags]",
		Short: Name + " is the workstation valet",
		Long:  `Reginald is the workstation valet for managing your workstation configuration and installed tools.`,
		Run:   runHelp,
	}

	return cmd
}

func runHelp(cmd *cobra.Command, _ []string) {
	if err := cmd.Help(); err != nil {
		fmt.Fprintln(os.Stderr, "Failed to run the help command")
		os.Exit(ExitError)
	}
}
