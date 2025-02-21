// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package cmd implements the command type for Reginald.
package cmd

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/anttikivi/reginald/internal/exit"
	"github.com/spf13/pflag"
)

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
	Run func(cmd *Command, args []string) error

	// Setup runs the setup required for the command. This includes tasks like
	// parsing the configuration.
	//
	// If the command is a child of another command, the Setup functions of the
	// parent functions are run first, starting from the root.
	Setup func(cmd *Command, args []string) error

	commands               []*Command     // list of children commands
	flags                  *pflag.FlagSet // flag set containing all of the flags for this command
	mutuallyExclusiveFlags [][]string     // each of the flag names marked as mutually exclusive
	parent                 *Command       // parent of this command, if this is a child command
}

// ContextKey is a key that is used for settings values for the command's
// context. The values that ContextKey can have are defined as constants.
type ContextKey uint8

// Values to use as context keys in the command context, passed to Execute.
const (
	VersionKey ContextKey = 1 << iota // key for the program's version
)

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

		// The version number is only set to the root command and propagated from there.
		cmds[i].Version = c.Root().Version
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
func (c *Command) Execute() error {
	if c.HasParent() {
		// Always start the execution from the root.
		if err := c.Root().Execute(); err != nil {
			return fmt.Errorf("%w", err)
		}

		return nil
	}

	args := os.Args[1:]

	// Get the global options out of the way.
	if err := c.Flags().Parse(args); err != nil {
		return fmt.Errorf("failed to parse the global command-line arguments: %w", err)
	}

	ok, err := c.checkStandardOptions()
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if ok {
		return nil
	}

	args = c.Flags().Args()
	cmd := c
	for len(args) > 0 {
		// The next argument should always be the next subcommand.
		name := args[0]

		// TODO: Extend this to allow having commands from plugins.
		nextCmd := cmd.Lookup(name)
		if nextCmd == nil {
			help(os.Stderr, cmd)
			fmt.Fprintf(os.Stderr, "Unknown subcommand: %s\n", name)

			return exit.New(exit.InvalidArgs, fmt.Errorf("%w: %s", errSubcommand, name))
		}

		cmd = nextCmd
		args = args[1:]
		if err := cmd.Flags().Parse(args); err != nil {
			fmt.Fprintln(os.Stderr, err.Error())
			help(os.Stderr, cmd)

			return fmt.Errorf("failed to parse the command-line arguments for %s: %w", cmd.Name(), err)
		}
	}

	if err := cmd.Flags().Parse(args); err != nil {
		return fmt.Errorf("%w", err)
	}

	println(cmd.Flags().Args())
	fmt.Println(cmd.Flags().Args())

	if err := cmd.Run(cmd, args); err != nil {
		return fmt.Errorf("failed to run the command: %w", err)
	}

	return nil
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

// checkStandardOptions checks if either '--version' or '--help' is set and runs
// the action required by the options. If either of the options is set or the
// program should exit due to an error, the function returns true. It also
// returns any error it encountered.
func (c *Command) checkStandardOptions() (bool, error) {
	ok, err := c.Flags().GetBool("version")
	if err != nil {
		return true, fmt.Errorf("failed to get value for the version option: %w", err)
	}

	if ok {
		printVersion(c)

		return true, nil
	}

	ok, err = c.Flags().GetBool("help")
	if err != nil {
		return true, fmt.Errorf("failed to get value for the version option: %w", err)
	}

	if ok {
		help(os.Stdout, c)

		return true, nil
	}

	return false, nil
}

// commandNameMatches checks if the two command names are equal.
//
// NOTE: This is implemented as a separate function in order to maybe extend it
// with case-insensitivity later.
func commandNameMatches(a, b string) bool {
	return a == b
}
