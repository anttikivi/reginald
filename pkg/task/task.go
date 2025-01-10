// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package task

// Task is a task that Reginald can run.
//
// Some of the most common tasks, like installing packages and creating the
// symbolic links, are included in Reginald, but more tasks can be defined as
// plugins.
type Task interface {
	// Check returns whether the provided configuration is valid.
	Check(cfg *Config) bool

	// Run runs the task.
	Run() error

	// Name gives the name of the task. Task name is used as its configuration
	// key.
	Type() string
}

// Config is the settings the user has given for a [Task].
type Config struct {
	// Type tells the type of the task. Reginald finds the correct task to run
	// by comparing this value to [Task.Type].
	Type string

	// Name is the unique name of the [Task]. Each task has either a
	// user-defined or an assigned unique name.
	Name string

	// Settings contains the rest of the provided configuration.
	Settings map[string]any `mapstructure:",remain"`
}
