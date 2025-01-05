package exit

// Code is a exit code for the program.
type Code int

// Error is an error returned by the program that contains the error that caused
// the program to fail and the desired exit code for the process.
type Error struct {
	Code Code
	Err  error
}

const (
	// Success is the exit code when the program is executed successfully.
	Success Code = 0

	// Failure is the exit code for generic or unknown errors.
	Failure Code = 1
)

func (e *Error) Error() string {
	return e.Err.Error()
}
