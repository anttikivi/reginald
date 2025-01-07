package runner

import (
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/anttikivi/reginald/internal/output"
)

// Runner is a helper for running external processes.
type Runner struct {
	DryRun        bool            // whether this is a dry run
	PrintCommands bool            // whether to print commands before running them, separate from dry run
	Printer       *output.Printer // the [output.Printer] of this run for printing from the runner
	Prompt        string          // prompt to print before commands when printing them.
}

// New creates a new instance of [Runner].
func New(p *output.Printer) *Runner {
	return &Runner{
		DryRun:        p.DryRun,
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

// Run runs the given command if this is not a dry run. It optionally, or if
// this is a dry run, prints the command before executing it.
func (r *Runner) Run(name string, args ...string) error {
	initialName := name

	name, err := r.LookPath(name)
	if err != nil {
		return fmt.Errorf("failed to look up %s from PATH: %w", initialName, err)
	}

	r.printCommand(name, args...)

	if r.DryRun {
		return nil
	}

	cmd := exec.Command(name, args...)
	cmd.Stderr = r.Printer.Err
	cmd.Stdout = r.Printer.Out

	if err = cmd.Run(); err != nil {
		return fmt.Errorf("failed to run %s: %w", r.quoteCommand(name, args...), err)
	}

	return nil
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

// printCommand prints the given command if the [Runner] is configured to print
// commands.
func (r *Runner) printCommand(name string, args ...string) {
	if r.DryRun {
		r.Printer.Println(r.quoteCommand(name, args...))
	} else if r.PrintCommands {
		r.Printer.GrayPrintln(r.quoteCommand(name, args...))
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
