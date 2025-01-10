// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/pkg/plugin"
	"github.com/anttikivi/reginald/pkg/task"
)

type InstallGo struct{}

func (p *InstallGo) Check(cfg *task.Config) bool {
	return cfg != nil
}

func (p *InstallGo) Run() error {
	return nil
}

func (p *InstallGo) Type() string {
	return "install-go"
}

func main() {
	server := plugin.NewTaskServer("install-go", []task.Task{&InstallGo{}})

	server.Describe()

	if err := server.Serve(); err != nil {
		fmt.Fprintf(os.Stderr, "Error while running the plugin server: %v", err)
		os.Exit(1)
	}
}
