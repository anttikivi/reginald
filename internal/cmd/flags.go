// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package cmd

import (
	"errors"
	"flag"
	"fmt"
	"strings"

	"github.com/anttikivi/reginald/internal/exit"
)

// errInvalidFlagType is the error returned if a flag has an unsupported type.
var errInvalidFlagType = errors.New("flag has an unsupported type")

var _ = errInvalidFlagType

// add adds the flags from src to the flags.
func addFlagSet(flags, src *flag.FlagSet) error {
	var err error

	src.VisitAll(func(f *flag.Flag) {
		if flags.Lookup(f.Name) != nil {
			switch v := f.Value.(type) {
			case flag.Getter:
				switch val := v.Get().(type) {
				case string:
					flags.String(f.Name, val, f.Usage)
				case int:
					flags.Int(f.Name, val, f.Usage)
				case bool:
					flags.Bool(f.Name, val, f.Usage)
				default:
					err = exit.New(exit.CommandInitFailure, fmt.Errorf("%w: %q", errInvalidFlagType, f.Name))
				}
			default:
				err = exit.New(exit.CommandInitFailure, fmt.Errorf("%w: %q", errInvalidFlagType, f.Name))
			}
		}
	})

	if err != nil {
		return fmt.Errorf("failed to merge flag sets: %w", err)
	}

	return nil
}

// trimFlags returns a copy of args with the command-line flags removed.
func trimFlags(args []string, flags *flag.FlagSet) []string {
	if len(args) == 0 {
		return args
	}

	cmds := make([]string, 0)

Loop:
	for len(args) > 0 {
		s := args[0]
		args = args[1:]

		switch {
		case s == "--":
			// Two dashes marks the end of the command-line flags.
			break Loop
		case strings.HasPrefix(s, "--") && !strings.Contains(s, "=") && isNonBool(s[2:], flags):
			// "--flag arg"
			// The user gave two dashes in front of the flag (as Go allows) and
			// the flag is not a boolean, so we have a value for the flag as the
			// next argument.
			fallthrough
		case strings.HasPrefix(s, "-") && !strings.Contains(s, "=") && isNonBool(s[1:], flags):
			// "-flag arg"
			// If there is only one argument left, we cannot delete the next
			// argument (the value for the flag), thus we can break the loop.
			if len(args) <= 1 {
				break Loop
			}

			// Remove the value for the flag.
			args = args[1:]
		case s != "" && !strings.HasPrefix(s, "-"):
			cmds = append(cmds, s)
		}
	}

	return cmds
}

// isNonBool returns whether the given flag is not a boolean flag.
//
// TODO: Do the return values need checking?
func isNonBool(name string, flags *flag.FlagSet) bool {
	f := flags.Lookup(name)
	if f == nil {
		return true
	}

	v, ok := f.Value.(flag.Getter)
	if !ok {
		return true
	}

	_, ok = v.Get().(bool)

	return !ok
}
