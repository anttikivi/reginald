package main

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/command"
)

func main() {
	cmd := command.NewReginaldCommand()

	if err := cmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(command.ExitError)
	}
}
