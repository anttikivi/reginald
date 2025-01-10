// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package task

// Task is a task that Reginald can run.
//
// Some of the most common tasks, like installing packages and creating the
// symbolic links, are included in Reginald, but more tasks can be defined as
// plugins.
type Task interface {
	// Name gives the name of the task. Task name is used as its configuration
	// key.
	Name() string

	// Run runs the task.
	Run() error
}
