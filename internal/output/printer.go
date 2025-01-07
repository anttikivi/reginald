package output

import (
	"fmt"
	"io"
	"os"

	"github.com/fatih/color"
)

// Printer is used for user output during the program run.
type Printer struct {
	Verbose bool      // whether verbose output is enabled
	Quiet   bool      // whether the program is configured to suppress output
	DryRun  bool      // whether this is a dry run
	Out     io.Writer // the writer for standard output messages
	Err     io.Writer // the writer for standard error output messages
}

// NewPrinter creates a new instance of [Printer].
func NewPrinter(verbose, quiet, dryRun bool) *Printer {
	return &Printer{
		Verbose: verbose,
		Quiet:   quiet,
		DryRun:  dryRun,
		Out:     os.Stdout,
		Err:     os.Stderr,
	}
}

func (p *Printer) Println(a ...any) {
	if !p.Quiet {
		fmt.Fprintln(p.Out, a...)
	}
}

func (p *Printer) GrayPrintln(a ...any) {
	if !p.Quiet {
		gray := color.New(color.FgHiBlack)
		s := gray.Sprint(a...)

		fmt.Fprintln(p.Out, s)
	}
}

func (p *Printer) Errorf(format string, a ...any) {
	if !p.Quiet {
		fmt.Fprintf(p.Err, format, a...)
	}
}

func (p *Printer) RedErrorf(format string, a ...any) {
	if !p.Quiet {
		s := color.RedString(format, a...)
		fmt.Fprint(p.Err, s)
	}
}
