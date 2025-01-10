package command

// Command is a command that Reginald can run.
type Command interface {
	// Name gives the name of the command. The command name is used as the
	// subcommand for Reginald that the user calls.
	Name() string

	// Run runs the command.
	Run() error
}
