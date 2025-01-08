package output

import (
	"fmt"
	"io"
	"os"
	"time"

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

func (p *Printer) Print(a ...any) {
	if !p.Quiet {
		fmt.Fprint(p.Out, a...)
	}
}

func (p *Printer) Printf(format string, a ...any) {
	if !p.Quiet {
		fmt.Fprintf(p.Out, format, a...)
	}
}

func (p *Printer) FaintPrintf(format string, a ...any) {
	if !p.Quiet {
		white := color.New(color.FgWhite).Add(color.Faint)
		s := white.Sprintf(format, a...)

		fmt.Fprint(p.Out, s)
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

func (p *Printer) GreenPrintln(a ...any) {
	if !p.Quiet {
		c := color.New(color.FgGreen)
		s := c.Sprint(a...)

		fmt.Fprintln(p.Out, s)
	}
}

func (p *Printer) Error(a ...any) {
	if !p.Quiet {
		fmt.Fprint(p.Err, a...)
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

func (p *Printer) YellowErrorf(format string, a ...any) {
	if !p.Quiet {
		s := color.YellowString(format, a...)
		fmt.Fprint(p.Err, s)
	}
}

func (p *Printer) YellowErrorln(a ...any) {
	if !p.Quiet {
		yellow := color.New(color.FgYellow)
		s := yellow.Sprint(a...)

		fmt.Fprintln(p.Err, s)
	}
}

func (p *Printer) Spinnerf(fn func() error, format string, a ...any) error {
	done := make(chan error, 1)

	go func() {
		err := fn()
		done <- err
		close(done)
	}()

	stop := make(chan struct{})

	go func() {
		chars := []rune{'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}
		i := 0

		for {
			select {
			case <-stop:
				p.Print("\r\033[K")

				return
			default:
				p.FaintPrintf("\r%c ", chars[i%len(chars)])
				p.FaintPrintf(format, a...)

				i++

				time.Sleep((1000 / 12) * time.Millisecond) //nolint:mnd // Calculate the FPS.
			}
		}
	}()

	err := <-done

	close(stop)
	p.Print("\r\033[K")

	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}
