package exit

type Code int

const (
	// Success is the exit code when the program is executed successfully.
	Success Code = 0

	// Error is the exit code for generic errors.
	Error Code = 1
)
