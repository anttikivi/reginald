// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package cmdutil implements common utilities needed by the commands.
//
// The cmdutil package accepts only utilities useful to multiple commands.
// Command-specific utilities should be implemented in the command packages.
package cmdutil

import (
	"log/slog"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/runner"
	"github.com/anttikivi/reginald/internal/ui"
	"github.com/spf13/cobra"
)

// CtxValues is a helper type for getting the common values for commands for
// the command context.
type CtxValues struct {
	Cfg     *config.Config // combined configuration for the program run
	Printer *ui.Printer    // printer for outputting to the user interface
	Runner  *runner.Runner // runner for executing external commands
}

// CtxValue is the type for the flags that can be used to determine which values
// to get from the context.
type CtxValue uint8

// Values for specifying which values to get from the command context.
const (
	ContextConfig  CtxValue                                         = 1 << iota // get the config
	ContextPrinter                                                              // get the printer
	ContextRunner                                                               // get the runner
	ContextAll     = ContextConfig | ContextPrinter | ContextRunner             // get all of the above
)

// ContextValues reads the specified values from the command context and returns
// them as a [CtxValues]. The function panics if its unable to get the values
// from the context.
func ContextValues(cmd *cobra.Command, values CtxValue) CtxValues {
	var ctxValues CtxValues

	if values&ContextConfig != 0 {
		cfg, ok := cmd.Context().Value(config.ConfigContextKey).(*config.Config)
		if !ok || cfg == nil {
			panic(exit.New(exit.CommandInitFailure, config.ErrNoConfig))
		}

		slog.Debug("Got the Config instance from context", slog.Any("cfg", cfg))

		ctxValues.Cfg = cfg
	}

	if values&ContextPrinter != 0 {
		p, ok := cmd.Context().Value(config.PrinterContextKey).(*ui.Printer)
		if !ok || p == nil {
			panic(exit.New(exit.CommandInitFailure, config.ErrNoPrinter))
		}

		slog.Debug("Got the Printer instance from context", slog.Any("printer", p))

		ctxValues.Printer = p
	}

	if values&ContextRunner != 0 {
		r, ok := cmd.Context().Value(config.RunnerContextKey).(*runner.Runner)
		if !ok || r == nil {
			panic(exit.New(exit.CommandInitFailure, config.ErrNoRunner))
		}

		slog.Debug("Got the Runner instance from context", slog.Any("runner", r))

		ctxValues.Runner = r
	}

	return ctxValues
}

// AllContextValues reads all of the common values for commands from the command
// context and returns them as a [CtxValues]. The function panics if its unable
// to get the values from the context.
func AllContextValues(cmd *cobra.Command) CtxValues {
	return ContextValues(cmd, ContextAll)
}
