// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package cmd implements the command type for Reginald.
//
// Parts of the code in this package are based on `spf13/cobra`, licensed under
// Apache-2.0. You can find the original source and license at
// https://github.com/spf13/cobra.
package cmd

import (
	"errors"
	"flag"
	"fmt"
	"strings"

	"github.com/anttikivi/reginald/internal/exit"
)

// Command is an implementation of a CLI command. In addition to the base
// command, all of the subcommands should be Commands.
type Command struct {
	// UsageLine is the one-line usage synopsis for the command. It should start
	// with the command name without including the parent commands.
	UsageLine string

	// Run runs the command. This should only execute the actual work that the
	// command does. The Setup function is used for setting up the command,
	// for example parsing the configuration.
	Run func(cmd *Command, args []string) error

	// Setup runs the setup required for the command. This includes tasks like
	// parsing the configuration.
	//
	// If the command is a child of another command, the Setup functions of the
	// parent functions are run first, starting from the root.
	Setup func(cmd *Command, args []string) error

	commands               []*Command    // list of children commands
	flags                  *flag.FlagSet // flag set containing all of the flags for this command
	globalFlags            *flag.FlagSet // flag set of the command that is inherited by children
	mutuallyExclusiveFlags [][]string    // each of the flag names marked as mutually exclusive
	parent                 *Command      // parent of this command, if this is a child command
}

var (
	// errFlagName is the error returned when an operation is performed on a flag
	// that does not exist.
	errFlagName = errors.New("flag does not exist")

	// errRecursiveChildCmd is the error returned when the user attempts to add a
	// command as a child of itself.
	errRecursiveChildCmd = errors.New("command cannot be a child of itself")
)

// Name returns the commands name.
func (c *Command) Name() string {
	n := c.UsageLine

	i := strings.Index(n, " ")
	if i != -1 {
		n = n[:i]
	}

	return n
}

// HasParent tells if this command has a parent, i.e. it is a child command.
func (c *Command) HasParent() bool {
	return c.parent != nil
}

// Add adds the given commands as children of this command.
func (c *Command) Add(cmds ...*Command) {
	for i, cmd := range cmds {
		if cmds[i] == c {
			panic(
				exit.New(
					exit.CommandInitFailure,
					fmt.Errorf("failed to add a child command: %w", errRecursiveChildCmd),
				),
			)
		}

		cmds[i].parent = c
		c.commands = append(c.commands, cmd)
	}
}

// Root returns the root command for this command.
func (c *Command) Root() *Command {
	if c.HasParent() {
		return c.parent.Root()
	}

	return c
}

// VisitParents executes the function fn on all of the command's parents.
func (c *Command) VisitParents(fn func(*Command)) {
	if c.HasParent() {
		fn(c.parent)
		c.parent.VisitParents(fn)
	}
}

// Flags returns the set of flags that contains all of the flags associated with
// this command.
func (c *Command) Flags() *flag.FlagSet {
	if c.flags == nil {
		c.flags = c.flagSet()
	}

	return c.flags
}

// GlobalFlags returns the set of flags of this command that are inherited by
// the child commands.
func (c *Command) GlobalFlags() *flag.FlagSet {
	if c.globalFlags == nil {
		c.globalFlags = c.flagSet()
	}

	return c.globalFlags
}

// MarkMutuallyExclusive marks the flags with the given names as mutually
// exclusive. It returns an error if one of the flags does not exist.
func (c *Command) MarkMutuallyExclusive(flags ...string) error {
	if err := c.mergeFlags(); err != nil {
		return fmt.Errorf("%w", err)
	}

	group := make([]string, 0, len(flags))

	for _, name := range flags {
		f := c.Flags().Lookup(name)
		if f != nil {
			return fmt.Errorf("%w: %s", errFlagName, name)
		}

		group = append(group, name)
	}

	if c.mutuallyExclusiveFlags == nil {
		c.mutuallyExclusiveFlags = make([][]string, 0)
	}

	c.mutuallyExclusiveFlags = append(c.mutuallyExclusiveFlags, group)

	return nil
}

// flagSet returns a new [flag.flagSet] for the command.
func (c *Command) flagSet() *flag.FlagSet {
	return flag.NewFlagSet(c.Name(), flag.ContinueOnError)
}

// mergeFlags merges the global flags of this command to the flags and adds the
// global flags from parents.
func (c *Command) mergeFlags() error {
	var err error

	err = addFlagSet(c.Root().GlobalFlags(), flag.CommandLine)
	if err != nil {
		return fmt.Errorf("failed to merge flags: %w", err)
	}

	c.VisitParents(func(p *Command) {
		e := addFlagSet(c.GlobalFlags(), p.GlobalFlags())
		if e != nil {
			err = e
		}
	})

	if err != nil {
		return fmt.Errorf("failed to merge flags: %w", err)
	}

	err = addFlagSet(c.Flags(), c.GlobalFlags())
	if err != nil {
		return fmt.Errorf("failed to merge flags: %w", err)
	}

	return nil
}
