// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package ui

import (
	"fmt"
	"io"
	"os"
	"time"

	"github.com/fatih/color"
)

// Printer is used for user output during the program run.
type Printer struct {
	Verbose bool // whether verbose output is enabled
	Quiet   bool // whether the program is configured to suppress output
}

// NewPrinter creates a new [Printer] for the program run.
func NewPrinter(verbose, quiet bool) *Printer {
	if quiet {
		verbose = false
	}

	return &Printer{
		Verbose: verbose,
		Quiet:   quiet,
	}
}

func (p *Printer) Err() io.Writer {
	return os.Stderr
}

func (p *Printer) Out() io.Writer {
	return os.Stdout
}

func PrintToErr(p *Printer, a ...any) {
	if !p.Quiet {
		printToErr(p, a...)
	}
}

func PrintfToErr(p *Printer, format string, a ...any) {
	if !p.Quiet {
		printfToErr(p, format, a...)
	}
}

func Printf(p *Printer, format string, a ...any) {
	if !p.Quiet {
		printfToOut(p, format, a...)
	}
}

func Errorf(p *Printer, format string, a ...any) {
	if !p.Quiet {
		colorPrintfToErr(p, color.FgRed, format, a...)
	}
}

func Verrorf(p *Printer, format string, a ...any) {
	if p.Verbose {
		colorPrintfToErr(p, color.FgRed, format, a...)
	}
}

func Hint(p *Printer, a ...any) {
	if !p.Quiet {
		colorPrintToOut(p, color.Faint, a...)
	}
}

func Hintf(p *Printer, format string, a ...any) {
	if !p.Quiet {
		colorPrintfToOut(p, color.Faint, format, a...)
	}
}

func Hintln(p *Printer, a ...any) {
	if !p.Quiet {
		colorPrintlnToOut(p, color.Faint, a...)
	}
}

func Successln(p *Printer, a ...any) {
	if !p.Quiet {
		colorPrintlnToOut(p, color.FgGreen, a...)
	}
}

func Warnf(p *Printer, format string, a ...any) {
	if !p.Quiet {
		colorPrintfToErr(p, color.FgYellow, format, a...)
	}
}

func Warnln(p *Printer, a ...any) {
	if !p.Quiet {
		colorPrintlnToErr(p, color.FgYellow, a...)
	}
}

func Vwarnf(p *Printer, format string, a ...any) {
	if p.Verbose {
		colorPrintfToErr(p, color.FgYellow, format, a...)
	}
}

func Spinnerf(printer *Printer, fn func() error, format string, a ...any) error {
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
				printToOut(printer, "\r\033[K")

				return
			default:
				Hintf(printer, "\r%c ", chars[i%len(chars)])
				Hintf(printer, format, a...)

				i++

				time.Sleep((1000 / 12) * time.Millisecond) //nolint:mnd // Calculate the FPS.
			}
		}
	}()

	err := <-done

	close(stop)
	printToOut(printer, "\r\033[K")

	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

//nolint:ireturn // Need to accept any return type.
func Spinner[T, R any](printer *Printer, fn func(R) T, msg string, a R) T {
	done := make(chan T)

	go func() {
		t := fn(a)
		done <- t
		close(done)
	}()

	stop := make(chan struct{})

	go func() {
		chars := []rune{'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}
		i := 0

		printToOut(printer, "\033[?25l")
		// defer printToOut(printer, "\033[?25h")

		for {
			select {
			case <-stop:
				// print(p, "\r\033[K")
				return
			default:
				printToOut(printer, "\033[s")
				Hintf(printer, "\033[999B\r%c ", chars[i%len(chars)])
				Hint(printer, msg)
				printToOut(printer, "\033[u")

				i++

				time.Sleep((1000 / 12) * time.Millisecond) //nolint:mnd // Calculate the FPS.
			}
		}
	}()

	result := <-done

	close(stop)
	printToOut(printer, "\033[s")
	printToOut(printer, "\033[u\033[K")
	printToOut(printer, "\033[?25h")

	return result
}

func printToOut(p *Printer, a ...any) {
	fmt.Fprint(p.Out(), a...)
}

func printfToOut(p *Printer, format string, a ...any) {
	fmt.Fprintf(p.Out(), format, a...)
}

func colorPrintToOut(p *Printer, c color.Attribute, a ...any) {
	cl := color.New(c)
	s := cl.Sprint(a...)

	fmt.Fprint(p.Out(), s)
}

func colorPrintfToOut(p *Printer, c color.Attribute, format string, a ...any) {
	cl := color.New(c)
	s := cl.Sprintf(format, a...)

	fmt.Fprint(p.Out(), s)
}

func colorPrintlnToOut(p *Printer, c color.Attribute, a ...any) {
	cl := color.New(c)
	s := cl.Sprint(a...)

	fmt.Fprintln(p.Out(), s)
}

func printToErr(p *Printer, a ...any) {
	fmt.Fprint(p.Err(), a...)
}

func printfToErr(p *Printer, format string, a ...any) {
	fmt.Fprintf(p.Err(), format, a...)
}

func colorPrintfToErr(p *Printer, c color.Attribute, format string, a ...any) {
	cl := color.New(c)
	s := cl.Sprintf(format, a...)

	fmt.Fprint(p.Err(), s)
}

func colorPrintlnToErr(p *Printer, c color.Attribute, a ...any) {
	cl := color.New(c)
	s := cl.Sprint(a...)

	fmt.Fprintln(p.Err(), s)
}
