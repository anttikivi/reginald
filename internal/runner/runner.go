// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package runner

import (
	"bytes"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/anttikivi/reginald/internal/ui"
)

// Runner is a helper for running external processes.
type Runner struct {
	DryRun        bool        // whether this is a dry run
	PrintCommands bool        // whether to print commands before running them, separate from dry run
	Printer       *ui.Printer // the [ui.Printer] of this run for printing from the runner
	Prompt        string      // prompt to print before commands when printing them
}

// New creates a new instance of [Runner].
func New(p *ui.Printer, dryRun bool) *Runner {
	return &Runner{
		DryRun:        dryRun,
		PrintCommands: p.Verbose,
		Printer:       p,
		Prompt:        "+",
	}
}

// LookPath searches for an executable named file in the directories named by
// the PATH environment variable. If file contains a slash, it is tried directly
// and the PATH is not consulted. Otherwise, on success, the result is an
// absolute path.
//
// If the executable is not found but the current run is marked as a dry run,
// instead of returning an error, LookPath returns the original string that was
// used so the program does not exit but can continue the dry run.
func (r *Runner) LookPath(file string) (string, error) {
	path, err := exec.LookPath(file)
	if err != nil {
		if r.DryRun {
			return file, nil
		}

		return "", fmt.Errorf("%w", err)
	}

	return path, nil
}

// Runf runs the given command if this is not a dry run. It optionally, or if
// this is a dry run, prints the command before executing it.
func (r *Runner) Run(name string, args ...string) error {
	cmd := make([]string, 0, len(args)+1)
	cmd = append(cmd, args...)

	if err := r.Runf(cmd, "Running %s...", r.quoteCommand(name, args...)); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// Runf runs the given command if this is not a dry run. It optionally, or if
// this is a dry run, prints the command before executing it.
//
// As opposed to [Runner.Run], Runf takes the command as an array and lets you
// specify in [fmt.Printf]-style what is printed while the command is executing.
func (r *Runner) Runf(command []string, format string, a ...any) error {
	initialName := command[0]

	name, err := r.LookPath(command[0])
	if err != nil {
		return fmt.Errorf("failed to look up %s from PATH: %w", initialName, err)
	}

	r.printCommand(name, command[1:]...)

	if r.DryRun {
		return nil
	}

	cmd := exec.Command(name, command[1:]...)

	var buf bytes.Buffer

	if r.Printer.Verbose {
		if err = r.runVerbose(cmd); err != nil {
			return fmt.Errorf("failed to run %s: %w", r.quoteCommand(name, command[1:]...), err)
		}

		return nil
	}

	cmd.Stderr = &buf
	cmd.Stdout = &buf

	if err = ui.Spinnerf(r.Printer, cmd.Run, format, a...); err != nil {
		ui.PrintToErr(r.Printer, buf.String())

		return fmt.Errorf("failed to run %s: %w", r.quoteCommand(name, command[1:]...), err)
	}

	return nil
}

// Output runs the command and returns its standard output.
func (r *Runner) Output(name string, args ...string) ([]byte, error) {
	initialName := name

	name, err := r.LookPath(name)
	if err != nil {
		return nil, fmt.Errorf("failed to look up %s from PATH: %w", initialName, err)
	}

	r.printCommand(name, args...)

	if r.DryRun {
		return nil, nil
	}

	cmd := exec.Command(name, args...)

	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to run %s: %w", r.quoteCommand(name, args...), err)
	}

	return out, nil
}

// IsExit returns a boolean indicating if the given error is an [exec.ExitError]
// and the exit code associated with the error.
func IsExit(err error) (int, bool) {
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode(), true
	}

	return 0, false
}

// runVerbose is a helper to run the `exec.Cmd` if the program output is set to
// be verbose or if you otherwise want the run to be verbose. It outputs the
// stderr and stdout from the command to the [ui.Printer] of this [Runner].
func (r *Runner) runVerbose(cmd *exec.Cmd) error {
	cmd.Stderr = r.Printer.Err()
	cmd.Stdout = r.Printer.Out()

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// printCommand prints the given command if the [Runner] is configured to print
// commands.
func (r *Runner) printCommand(name string, args ...string) {
	if r.DryRun || r.PrintCommands {
		ui.Hintln(r.Printer, r.quoteCommand(name, args...))
	}
}

// quoteCommand quotes a command for printing.
func (r *Runner) quoteCommand(name string, args ...string) string {
	var s string

	quoted := make([]string, 0, len(args)+2) //nolint:mnd // Add the prompt and the name.
	quoted = append(quoted, r.Prompt, quoteArg(name))

	for _, a := range args {
		quoted = append(quoted, quoteArg(a))
	}

	s = strings.Join(quoted, " ")

	return s
}

// quoteArg quotes a single command-line argument for printing.
func quoteArg(arg string) string {
	if strings.ContainsAny(arg, " \t\n\"'$&|<>") {
		return strconv.Quote(arg)
	}

	return arg
}
