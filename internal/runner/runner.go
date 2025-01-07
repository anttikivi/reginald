package runner

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/anttikivi/reginald/internal/output"
)

// Runner is a helper for running external processes.
type Runner struct {
	DryRun  bool            // whether this is a dry run
	Printer *output.Printer // the [output.Printer] of this run for printing from the runner
}

// New creates a new instance of [Runner].
func New(p *output.Printer) *Runner {
	return &Runner{
		DryRun:  p.DryRun,
		Printer: p,
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
func (r *Runner) Run(name string, args ...string) {
	fmt.Fprintf(os.Stderr, "Name: %s, args: %v\n", name, args)
}
