// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package apply contains the `apply` command of the program.
package apply

import (
	"log/slog"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/runner"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/anttikivi/reginald/internal/ui"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// helpDescription is the description printed when the command is run with the
// `--help` flag.
//
//nolint:gochecknoglobals,lll // It is easier to have this here instead of inlining.
var helpDescription = ``

// NewCommand creates a new instance of the bootstrap command.
//
//nolint:lll // Cannot really make the help messages shorter.
func NewCommand(vpr *viper.Viper) *cobra.Command {
	cmd := &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:               constants.ApplyCommandName,
		Aliases:           []string{"install"},
		Short:             "Ask " + constants.Name + " to install your environment",
		Long:              strutil.Cap(helpDescription, constants.HelpLineLen),
		PersistentPreRunE: persistentPreRun,
		RunE:              run,
		SilenceErrors:     true,
		SilenceUsage:      true,
	}

	return cmd
}

func persistentPreRun(cmd *cobra.Command, args []string) error {
	slog.Info("Running the persistent pre-run", "cmd", constants.ApplyCommandName)

	cfg, ok := cmd.Context().Value(config.ConfigContextKey).(*config.Config)
	if !ok || cfg == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoConfig))
	}

	slog.Debug("Got the Config instance from context", slog.Any("cfg", cfg))

	p, ok := cmd.Context().Value(config.PrinterContextKey).(*ui.Printer)
	if !ok || p == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoPrinter))
	}

	slog.Debug("Got the Printer instance from context", slog.Any("printer", p))

	if _, err := ui.Spinner(p, checkPluginConfigs, "Checking the plugin configs...", cfg); err != nil {
		return err
	}

	return nil
}

func run(cmd *cobra.Command, _ []string) error {
	slog.Info("Running the command", "cmd", constants.ApplyCommandName)

	cfg, ok := cmd.Context().Value(config.ConfigContextKey).(*config.Config)
	if !ok || cfg == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoConfig))
	}

	slog.Debug("Got the Config instance from context", slog.Any("cfg", cfg))

	p, ok := cmd.Context().Value(config.PrinterContextKey).(*ui.Printer)
	if !ok || p == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoPrinter))
	}

	slog.Debug("Got the Printer instance from context", slog.Any("printer", p))

	r, ok := cmd.Context().Value(config.RunnerContextKey).(*runner.Runner)
	if !ok || r == nil {
		panic(exit.New(exit.CommandInitFailure, config.ErrNoRunner))
	}

	slog.Debug("Got the Runner instance from context", slog.Any("runner", r))

	ui.Successln(p, "Apply done")

	return nil
}
