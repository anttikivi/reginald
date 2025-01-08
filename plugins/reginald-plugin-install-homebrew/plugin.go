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

func (p *InstallHomebrew) Run() error {
	fmt.Fprintln(os.Stdout, "Installing Homebrew")

	return nil
}

func main() {
	fmt.Fprintln(os.Stdout, "Hello from plugin")
	p := &InstallHomebrew{}
	plugins := map[string]plugin.Plugin{
		"install-homebrew": &task.TaskPlugin{Impl: p},
	}

	plugin.ServeTask(plugins)
}
