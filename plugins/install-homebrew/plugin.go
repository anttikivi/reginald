// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/pkg/plugin"
	"github.com/anttikivi/reginald/pkg/task"
)

type InstallHomebrew struct{}

func (p *InstallHomebrew) Name() string {
	return "install-homebrew"
}

func (p *InstallHomebrew) Run() error {
	fmt.Fprintln(os.Stdout, "Installing Homebrew")

	return nil
}

func main() {
	server := plugin.NewTaskServer("install-homebrew", []task.Task{&InstallHomebrew{}})

	server.Describe()

	fmt.Fprintln(os.Stdout, "Hello from plugin")

	if err := server.Serve(); err != nil {
		fmt.Fprintf(os.Stderr, "Error while running the plugin server: %v", err)
		os.Exit(1)
	}
}
