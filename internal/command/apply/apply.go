// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

// Package apply contains the `apply` command of the program.
package apply

import (
	"errors"
	"fmt"
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
//nolint:gochecknoglobals // It is easier to have this here instead of inlining.
var helpDescription = ``

// NewCommand creates a new instance of the bootstrap command.
func NewCommand(_ *viper.Viper) *cobra.Command {
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

func persistentPreRun(cmd *cobra.Command, _ []string) error {
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

	if err := assignTaskNames(cfg); err != nil {
		return fmt.Errorf("failed to assign the task names: %w", err)
	}

	slog.Debug("Assigned the task names", "tasks", cfg.Tasks)

	opts := checkOptions{
		printer: p,
		cfg:     cfg,
	}

	if err := ui.Spinner(p, checkTaskDefaults, "Checking the task defaults...", opts); err != nil {
		if errors.Is(err, errCheckDefaults) {
			ui.Errorf(p, "%v\n", err)

			return exit.New(exit.InvalidConfig, fmt.Errorf("%w", errCheckDefaults))
		}

		panic(
			exit.New(
				exit.CommandInitFailure,
				fmt.Errorf("unexpected error while checking the defaults for tasks: %w", err),
			),
		)
	}

	cfg = mergeDefaults(cfg)

	slog.Debug("Merged the default settings", "cfg", cfg)

	if err := ui.Spinner(p, checkTaskConfigs, "Checking the task configs...", opts); err != nil {
		if errors.Is(err, errCheckConfigs) {
			ui.Errorf(p, "%v\n", err)

			return exit.New(exit.InvalidConfig, fmt.Errorf("%w", errCheckConfigs))
		}

		panic(
			exit.New(
				exit.CommandInitFailure,
				fmt.Errorf("unexpected error while checking the configs for tasks: %w", err),
			),
		)
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
