// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package base implements the base command for Reginald.
package base

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/cmd"
	"github.com/anttikivi/reginald/internal/cmd/apply"
	"github.com/anttikivi/reginald/internal/errutil"
)

// Name of base command.
const Name = "reggie"

// New returns a new Reginald command with version v.
func New(v string) (*cmd.Command, error) {
	//nolint:exhaustruct // Using default values for other fields.
	c := &cmd.Command{
		UsageLine: Name,
		Version:   v,
		Run:       run,
		Setup:     setup,
	}

	c.Flags().BoolP("version", "V", false, "Print the version information and exit.")
	c.Flags().BoolP("help", "h", false, "Print this help message and exit.")

	// c.Flags().Bool("no-color", false, "Disable colors in the command line output.")
	c.Flags().BoolP("verbose", "v", false, "Print more verbose output.")
	c.Flags().BoolP("quiet", "q", false, "Disable printing output.")

	if err := c.MarkMutuallyExclusive("verbose", "quiet"); err != nil {
		return nil, errutil.New(
			errutil.CommandInitFailure,
			fmt.Errorf("failed to mark %q and %q as mutually exclusive: %w", "v", "q", err),
		)
	}

	c.Flags().BoolP("dry-run", "n", false, "Print the commands but do not run them.")

	applyCmd := apply.New()

	c.Add(applyCmd)

	return c, nil
}

func run(_ *cmd.Command, _ []string) error {
	// c.Flags().Usage()
	fmt.Fprintln(os.Stdout, "Base command run")

	return nil
}

func setup(_ *cmd.Command, _ []string) error {
	return nil
}
