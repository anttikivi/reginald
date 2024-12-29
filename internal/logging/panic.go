package logging

import (
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

// An exit code of 11 keeps us out of the way of the detailed exit codes and
// also happens to be the same code as SIGSEGV which is roughly the same type
// of condition that causes most panics.
const exitCode = 11

// In case multiple goroutines panic concurrently, ensure only the first one
// recovered by HandlePanic starts printing.
var panicMutex sync.Mutex //nolint:gochecknoglobals // the mutex needs to be global to share it between goroutines

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

func handle(recovered interface{}, trace []byte) {
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

	os.Exit(exitCode)
}
