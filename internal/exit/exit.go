// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package exit

import (
	"errors"
	"fmt"
)

// Code is a exit code for the program.
type Code int

// Error is an error returned by the program that contains the error that caused
// the program to fail and the desired exit code for the process.
type Error struct {
	c   Code
	err error
}

const (
	// Success is the exit code when the program is executed successfully.
	Success Code = 0

	// Failure is the exit code for generic or unknown errors.
	Failure Code = 1

	// ExecFailure is the exit code for when a call to a [exec.Command] fails
	// and no exit code is available.
	ExecFailure Code = 2

	// User errors.

	// InvalidConfig is the exit code for when the program fails due to invalid
	// configuration.
	InvalidConfig Code = 3

	// InvalidConfigFile is the exit code for when the program fails to read the
	// config file.
	InvalidConfigFile Code = 4

	// Internal errors.

	// NewErrorFailure is the exit code when there is an attempt to create a new
	// [Error] with invalid values.
	NewErrorFailure Code = 11

	// CommandInitFailure is the exit code when creating the command instance
	// fails.
	CommandInitFailure Code = 12

	// CommandRunFailure is the exit code when the command run fails due to an
	// unexpected error.
	CommandRunFailure Code = 13
)

var (
	errInvalidCode = errors.New("invalid exit code")
	errNilError    = errors.New("nil error")
)

func (e *Error) Code() Code {
	return e.c
}

func (e *Error) Error() string {
	return fmt.Sprintf("%v (%d)", e.err.Error(), e.c)
}

func New(c Code, err error) *Error {
	if err == nil && c < 0 {
		panic(&Error{c: NewErrorFailure, err: fmt.Errorf("%w with %w %d", errNilError, errInvalidCode, c)})
	}

	if err == nil {
		panic(&Error{c: NewErrorFailure, err: fmt.Errorf("%w with exit code %d", errNilError, c)})
	}

	if c < 0 {
		panic(&Error{c: NewErrorFailure, err: fmt.Errorf("%w %d with error: %w", errInvalidCode, c, err)})
	}

	return &Error{c, err}
}
