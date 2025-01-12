// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"log/slog"
	"os"

	"github.com/anttikivi/reginald/pkg/plugin"
	"github.com/anttikivi/reginald/pkg/task"
)

type InstallGo struct{}

func (t *InstallGo) Check(settings task.Settings) error {
	slog.Debug("Checking the task config", "task", t.Type(), "settings", settings)

	if len(settings) > 0 {
		for k := range settings {
			//nolint:wrapcheck // The return value cannot be wrapped to catch it at host.
			return task.NewInvalidKey(t, k)
		}
	}

	return nil
}

func (t *InstallGo) CheckDefaults(settings task.Settings) error {
	slog.Debug("Checking the task defaults", "task", t.Type(), "settings", settings)

	if len(settings) > 0 {
		for k := range settings {
			//nolint:wrapcheck // The return value cannot be wrapped to catch it at host.
			return task.NewInvalidKey(t, k)
		}
	}

	return nil
}

func (t *InstallGo) Run(_ *task.Config) error {
	return nil
}

func (t *InstallGo) Type() string {
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
