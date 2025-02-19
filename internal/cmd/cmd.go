// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package cmd implements the command type for Reginald.
package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/anttikivi/reginald/internal/exit"
	"github.com/spf13/pflag"
)

// ContextKey is a key that is used for settings values for the command's
// context.
type ContextKey string

// Command is an implementation of a CLI command. In addition to the base
// command, all of the subcommands should be Commands.
type Command struct {
	// UsageLine is the one-line usage synopsis for the command. It should start
	// with the command name without including the parent commands.
	UsageLine string

	// Aliases are aliases for this command that can be used instead of the
	// first word in UsageLine.
	Aliases []string

	// Version is the version of this command.
	Version string

	// Whether to disable the persistent flags for this command and only use the
	// given local flags.
	DisablePersistentFlags bool

	// Run runs the command. This should only execute the actual work that the
	// command does. The Setup function is used for setting up the command,
	// for example parsing the configuration.
	Run func(ctx context.Context, cmd *Command, args []string) error

	// Setup runs the setup required for the command. This includes tasks like
	// parsing the configuration.
	//
	// If the command is a child of another command, the Setup functions of the
	// parent functions are run first, starting from the root.
	Setup func(ctx context.Context, cmd *Command, args []string) error

	commands               []*Command     // list of children commands
	flags                  *pflag.FlagSet // flag set containing all of the flags for this command
	mutuallyExclusiveFlags [][]string     // each of the flag names marked as mutually exclusive
	parent                 *Command       // parent of this command, if this is a child command
}

var (
	// errContextValue is the error returned when trying to get a nil value from
	// the command context.
	// TODO: This will be used.
	// errContextValue = errors.New("no value associated with the key in the command context").

	// errFlagName is the error returned when an operation is performed on a flag
	// that does not exist.
	errFlagName = errors.New("flag does not exist")

	// errSubcommand is the error returned when running with an invalid
	// subcommand.
	errSubcommand = errors.New("invalid subcommand")

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

// HasAlias returns whether the given string is an alias for the command.
func (c *Command) HasAlias(s string) bool {
	for _, a := range c.Aliases {
		if commandNameMatches(a, s) {
			return true
		}
	}

	return false
}

// Runnable returns whether the command can be run.
func (c *Command) Runnable() bool {
	return c.Run != nil
}

// Lookup returns the subcommand for this command for the given name, if any.
// Otherwise it returns nil.
func (c *Command) Lookup(name string) *Command {
	for _, cmd := range c.commands {
		if cmd.Name() == name {
			return cmd
		}
	}

	return nil
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

// Execute finds the commands to run from the command tree by checking the
// command-line arguments, parses the command-line arguments, and sets up and
// runs the command.
func (c *Command) Execute(ctx context.Context) error {
	if c.HasParent() {
		// Always start the execution from the root.
		if err := c.Root().Execute(ctx); err != nil {
			return fmt.Errorf("%w", err)
		}

		return nil
	}

	// TODO: Should the global flag set be merged into the root command's flags?
	// pflag.Parse()

	args := os.Args[1:]
	// if len(args) < 1 {
	// 	// TODO: Add a custom usage function.
	// 	c.Flags().Usage()
	//
	// 	return nil
	// }

	// if args[0] == "help" {
	// 	// If the subcommand is "help", run it and exit early.
	// 	// TODO: Implement help.
	// 	return nil
	// }

	cmd := c
	for len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		// TODO: Extend this to allow having commands from plugins.
		cmd = cmd.Lookup(args[0])
		if cmd == nil {
			return exit.New(exit.InvalidArgs, fmt.Errorf("%w: %s", errSubcommand, args[0]))
		}

		args = args[1:]
	}

	if err := cmd.Flags().Parse(args); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := cmd.Run(ctx, cmd, args); err != nil {
		return fmt.Errorf("failed to run the command: %w", err)
	}

	return nil
}

// VisitParents executes the function fn on all of the command's parents.
func (c *Command) VisitParents(fn func(*Command)) {
	if c.HasParent() {
		fn(c.parent)
		c.parent.VisitParents(fn)
	}
}

// Flags returns the set of flags that contains the flags associated with this
// command.
func (c *Command) Flags() *pflag.FlagSet {
	if c.flags == nil {
		f := pflag.NewFlagSet(c.Name(), pflag.ContinueOnError)
		c.flags = f
		c.flags.Usage = func() {
			fmt.Fprintf(os.Stderr, "Usage of %s:\n", c.Name())
			c.flags.PrintDefaults()
		}
	}

	return c.flags
}

// MarkMutuallyExclusive marks the flags with the given names as mutually
// exclusive. It returns an error if one of the flags does not exist.
func (c *Command) MarkMutuallyExclusive(flags ...string) error {
	group := make([]string, 0, len(flags))

	for _, name := range flags {
		f := c.Flags().Lookup(name)
		if f == nil {
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

// commandNameMatches checks if the two command names are equal.
//
// NOTE: This is implemented as a separate function in order to maybe extend it
// with case-insensitivity later.
func commandNameMatches(a, b string) bool {
	return a == b
}
