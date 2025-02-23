// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package base implements the base command for Reginald.
package apply

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/cmd"
)

// Name of base command.
const Name = "apply"

// New returns a new `apply` command.
func New() *cmd.Command {
	//nolint:exhaustruct // Using default values for other fields.
	c := &cmd.Command{
		UsageLine: Name,
		Run:       run,
		Setup:     setup,
	}

	c.Flags().StringP("config", "c", "", "The configuration file to use.")

	return c
}

func run(_ *cmd.Command, _ []string) error {
	// c.Flags().Usage()
	fmt.Fprintln(os.Stdout, "Run apply")

	return nil
}

func setup(_ *cmd.Command, _ []string) error {
	return nil
}
