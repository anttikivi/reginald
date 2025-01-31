// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package cmd implements the command type for Reginald.
package cmd

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/anttikivi/reginald/internal/exit"
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

	commands               []*Command      // list of children commands
	ctx                    context.Context // context associated with this command
	flags                  *flag.FlagSet   // flag set containing all of the flags for this command
	persistentFlags        *flag.FlagSet   // flag set of the command that is inherited by children
	globalFlags            *flag.FlagSet   // global flags in the root command that can be set before the subcommand
	mutuallyExclusiveFlags [][]string      // each of the flag names marked as mutually exclusive
	parent                 *Command        // parent of this command, if this is a child command
}

var (
	// errContextValue is the error returned when trying to get a nil value from
	// the command context.
	errContextValue = errors.New("no value associated with the key in the command context")

	// errFlagName is the error returned when an operation is performed on a flag
	// that does not exist.
	errFlagName = errors.New("flag does not exist")

	// errGlobalFlags is the error returned when trying to get the global flags
	// from a non-root command.
	errGlobalFlags = errors.New("failed to get the global flags as the command is not the root command")

	// errSubcommand is the error returned when running with an invalid
	// subcommand.
	errSubcommand = errors.New("invalid subcommand")

	// errRecursiveChildCmd is the error returned when the user attempts to add a
	// command as a child of itself.
	errRecursiveChildCmd = errors.New("command cannot be a child of itself")
)

// Context returns the command context. If no context has been set, the context
// is [context.Background] by default.
func (c *Command) Context() context.Context {
	if c.ctx == nil {
		c.ctx = context.Background()
	}

	return c.ctx
}

// Value returns the value associated with the command's context for key, or nil
// if no value is associated with key. Successive calls to Value with the same
// key returns the same result. The function panics if the value is nil.
func (c *Command) Value(key ContextKey) any {
	val := c.ctx.Value(key)
	if val == nil {
		panic(exit.New(exit.CommandRunFailure, fmt.Errorf("%w: %v", errContextValue, key)))
	}

	return val
}

// WithValue sets the command context to a copy of itself in which the value
// associated with key is val.
func (c *Command) WithValue(key ContextKey, val any) {
	c.ctx = context.WithValue(c.ctx, key, val)
}

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

		// As child commands cannot have global flags, move them to the root
		// before adding the command to the root.
		addFlagSet(c.Root().GlobalFlags(), cmd.GlobalFlags())
		cmd.globalFlags = nil

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

	if ctx == nil {
		ctx = context.Background()
	}

	c.ctx = ctx

	args := c.collectGlobalFlags(os.Args[1:])

	if err := c.GlobalFlags().Parse(args); err != nil {
		return fmt.Errorf("%w", err)
	}

	args = c.GlobalFlags().Args()
	cmd := c

	// We stop looking for the subcommand at the first flag.
	for len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd = cmd.Lookup(args[0])
		if cmd == nil {
			return exit.New(exit.InvalidArgs, fmt.Errorf("%w: %s", errSubcommand, args[0]))
		}

		args = args[1:]
	}

	cmd.mergeFlags()

	if err := cmd.Flags().Parse(args); err != nil {
		return fmt.Errorf("%w", err)
	}

	cmd.Run(cmd, args)

	return nil
}

func (c *Command) findCmd() {}

// VisitParents executes the function fn on all of the command's parents.
func (c *Command) VisitParents(fn func(*Command)) {
	if c.HasParent() {
		fn(c.parent)
		c.parent.VisitParents(fn)
	}
}

// Flags returns the set of flags that contains all of the flags but the global
// flags associated with this command.
func (c *Command) Flags() *flag.FlagSet {
	if c.flags == nil {
		c.flags = c.flagSet()
	}

	return c.flags
}

// PersistentFlags returns the set of flags of this command that are inherited
// by the child commands.
func (c *Command) PersistentFlags() *flag.FlagSet {
	if c.persistentFlags == nil {
		c.persistentFlags = c.flagSet()
	}

	return c.persistentFlags
}

// GlobalFlags returns the set of global flags in the root command that can be
// set before the subcommand.
func (c *Command) GlobalFlags() *flag.FlagSet {
	if c.HasParent() {
		panic(exit.New(exit.CommandInitFailure, fmt.Errorf("%w: %s", errGlobalFlags, c.Name())))
	}

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

	err = addFlagSet(c.Root().PersistentFlags(), flag.CommandLine)
	if err != nil {
		return fmt.Errorf("failed to merge flags: %w", err)
	}

	c.VisitParents(func(p *Command) {
		e := addFlagSet(c.PersistentFlags(), p.PersistentFlags())
		if e != nil {
			err = e
		}
	})

	if err != nil {
		return fmt.Errorf("failed to merge flags: %w", err)
	}

	err = addFlagSet(c.Flags(), c.PersistentFlags())
	if err != nil {
		return fmt.Errorf("failed to merge flags: %w", err)
	}

	return nil
}

// collectGlobalFlags finds the global flags in the global flags from the args
// and moves them first for the global flag parser. The function returns a new
// slice with the modified arguments.
func (c *Command) collectGlobalFlags(args []string) []string {
	newArgs := make([]string, 0, len(args))
	rest := make([]string, 0)

	c.mergeFlags()

Loop:
	for len(args) > 0 {
		s := args[0]
		dashes := strings.IndexFunc(s, func(r rune) bool { return r != '-' })
		equal := strings.Index(s, "=")

		args = args[1:]

		switch {
		case s == "--":
			// Two dashes marks the end of the command-line flags.
			break Loop
		case dashes != 1 && dashes != 2:
			// Not a flag.
			rest = append(rest, s)
		case equal > 0:
			// Flag with an equals sign.
			name := s[dashes:equal]

			f := c.GlobalFlags().Lookup(name)
			if f != nil {
				newArgs = append(newArgs, s)
			} else {
				rest = append(rest, s)
			}
		case isNonBool(s[dashes:], c.Flags()) && isNonBool(s[dashes:], c.GlobalFlags()):
			// "--flag arg" or "-flag arg"
			// The user gave two dashes in front of the flag (as Go allows) and
			// the flag is not a boolean, so we have a value for the flag as the
			// next argument.
			f := c.GlobalFlags().Lookup(s[dashes:])
			if f != nil {
				newArgs = append(newArgs, s)
			} else {
				rest = append(rest, s)
			}

			if len(args) <= 1 {
				break Loop
			}

			if f != nil {
				newArgs = append(newArgs, args[0])
			} else {
				rest = append(rest, args[0])
			}

			args = args[1:]
		case s != "":
			// "--flag" or "-flag"
			f := c.GlobalFlags().Lookup(s[dashes:])
			if f != nil {
				newArgs = append(newArgs, s)
			} else {
				rest = append(rest, s)
			}
		}
	}

	newArgs = append(newArgs, rest...)

	return newArgs
}

// commandNameMatches checks if the two command names are equal.
//
// NOTE: This is implemented as a separate function in order to maybe extend it
// with case-insensitivity later.
func commandNameMatches(a, b string) bool {
	return a == b
}
