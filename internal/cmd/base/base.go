// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package base implements the base command for Reginald.
package base

import (
	"fmt"

	"github.com/anttikivi/reginald/internal/cmd"
	"github.com/anttikivi/reginald/internal/exit"
)

// Name of base command.
const Name = "rgl"

func New() (*cmd.Command, error) {
	c := &cmd.Command{
		UsageLine: Name,
		Run:       run,
		Setup:     setup,
	}

	c.GlobalFlags().Bool("no-color", false, "Disable colors in the command line output.")
	c.GlobalFlags().Bool("v", false, "Print more verbose output.")
	c.GlobalFlags().Bool("q", false, "Disable printing output.")

	if err := c.MarkMutuallyExclusive("v", "q"); err != nil {
		return nil, exit.New(
			exit.CommandInitFailure,
			fmt.Errorf("failed to mark %q and %q as mutually exclusive: %w", "v", "q", err),
		)
	}

	c.GlobalFlags().Bool("n", false, "Print the commands but do not run them.")

	return c, nil
}

func run(_ *cmd.Command, _ []string) error {
	return nil
}

func setup(_ *cmd.Command, _ []string) error {
	return nil
}
