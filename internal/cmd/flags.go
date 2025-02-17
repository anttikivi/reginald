// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package cmd

import (
	"errors"
	"flag"
	"fmt"

	"github.com/anttikivi/reginald/internal/exit"
)

// errInvalidFlagType is the error returned if a flag has an unsupported type.
var errInvalidFlagType = errors.New("flag has an unsupported type")

var _ = errInvalidFlagType

// add adds the flags from src to the flags.
func addFlagSet(flags, src *flag.FlagSet) error {
	var err error

	src.VisitAll(func(f *flag.Flag) {
		if flags.Lookup(f.Name) == nil {
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
