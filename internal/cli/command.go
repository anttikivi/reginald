package cli

import "flag"

// Command is an implementation of a CLI command. In addition to the base
// command, all of the subcommands should be Commands.
type Command struct {
	Flags *flag.FlagSet // the flags associated with this command
}
