// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package base implements the base command for Reginald.
package base

import (
	"context"
	"fmt"

	"github.com/anttikivi/reginald/internal/cmd"
	"github.com/anttikivi/reginald/internal/cmd/version"
	"github.com/anttikivi/reginald/internal/exit"
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

	c.PersistentFlags().Bool("no-color", false, "Disable colors in the command line output.")
	c.PersistentFlags().Bool("v", false, "Print more verbose output.")
	c.PersistentFlags().Bool("q", false, "Disable printing output.")

	if err := c.MarkMutuallyExclusive("v", "q"); err != nil {
		return nil, exit.New(
			exit.CommandInitFailure,
			fmt.Errorf("failed to mark %q and %q as mutually exclusive: %w", "v", "q", err),
		)
	}

	c.PersistentFlags().Bool("n", false, "Print the commands but do not run them.")

	versionCmd, err := version.New(v)
	if err != nil {
		return nil, exit.New(
			exit.CommandInitFailure,
			fmt.Errorf("failed to initialize the %q command: %w", version.Name, err),
		)
	}

	c.Add(versionCmd)

	return c, nil
}

func run(_ context.Context, c *cmd.Command, _ []string) error {
	c.Flags().Usage()

	return nil
}

func setup(_ context.Context, _ *cmd.Command, _ []string) error {
	return nil
}
