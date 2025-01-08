// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package exit

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"strings"
	"sync"

	"github.com/anttikivi/reginald/internal/constants"
)

const panicOutput = `
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! %[1]s PANIC !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

%[2]s panicked! This is always indicative of a bug within our little valet.
Please report the crash with %[2]s[1] so that we can fix this.

When reporting bugs, please include your %[2]s version, the stack trace
shown below, and any additional information which may help replicate the issue.

[1]: %[3]s

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! %[1]s PANIC !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

`

// In case multiple goroutines panic concurrently, ensure only the first one
// recovered by HandlePanic starts printing.
//
//nolint:gochecknoglobals // The mutex needs to be global to share it between goroutines.
var panicMutex sync.Mutex

// HandlePanic is called to recover from an internal panic in Reginald and
// augments the standard stack trace with a helpful error message.
// It must be called as a deferred function and must be the first deferred
// function call at the start of a new goroutine.
func HandlePanic() {
	panicMutex.Lock()
	defer panicMutex.Unlock()

	recovered := recover()
	handle(recovered, nil)
}

func handle(recovered any, trace []byte) {
	if recovered == nil {
		return
	}

	fmt.Fprintf(os.Stderr, panicOutput, strings.ToUpper(constants.Name), constants.Name, constants.IssuesURL)
	fmt.Fprint(os.Stderr, recovered, "\n")

	// When called from a deferred function, debug.PrintStack will include the
	// full stack from the point of the pending panic.
	debug.PrintStack()

	if trace != nil {
		fmt.Fprint(os.Stderr, "With goroutine called from:\n")
		os.Stderr.Write(trace)
	}

	if err, ok := recovered.(error); ok {
		var exitError *Error
		if errors.As(err, &exitError) {
			os.Exit(int(exitError.Code()))
		}
	}

	os.Exit(int(Failure))
}
