// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package task

import (
	"fmt"
	"log/slog"
	"strconv"
)

// Settings are the user-provided configurations options for a task.
type Settings map[string]any

// Task is a task that Reginald can run.
//
// Some of the most common tasks, like installing packages and creating the
// symbolic links, are included in Reginald, but more tasks can be defined as
// plugins.
type Task interface {
	// Check returns whether the provided configuration is valid. Returning a
	// nil error from the function indicates that there are no errors. If the
	// function finds invalid configuration settings, it should return a
	// [ConfigError].
	Check(settings Settings) error

	// CheckDefaults returns the provided defaults configuration is valid.
	// Returning a nil error from the function indicates that there are no
	// errors. If the function finds invalid configuration settings, it should
	// return a [ConfigError].
	CheckDefaults(settings Settings) error

	// Run runs the task.
	Run(cfg *Config) error

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
	Settings Settings `mapstructure:",remain"`
}

// ConfigList contains all of the provided task configuration in order.
type ConfigList []*Config

type ConfigViolation int

// ConfigError is the error type to use in the configuration checking functions
// [Task.Check] and [Task.CheckDefaults]. Reginald uses the values from the
// error to display a more helpful error message to the user.
type ConfigError struct {
	Type     ConfigViolation // the type of the violation that caused this error
	Task     string          // the task that caused this error
	Key      string          // the key that caused the error
	Value    any             // the value that caused the error
	ShouldBe string          // the type the config should have
}

// Types that [ConfigError] uses to determine if it is caused by an invalid key
// or value.
const (
	InvalidKey   ConfigViolation = iota // the config contains an invalid key
	InvalidValue                        // the config contains an invalid value
	InvalidType                         // the config contains a setting that has invalid type
)

func (c ConfigList) LogValue() slog.Value {
	value := make([]slog.Attr, 0, len(c))

	for i, cfg := range c {
		value = append(
			value,
			slog.Group(
				strconv.Itoa(i),
				slog.String("type", cfg.Type),
				slog.String("name", cfg.Name),
				slog.Any("settings", cfg.Settings),
			),
		)
	}

	return slog.GroupValue(value...)
}

// NewInvalidKey returns a new [ConfigError] for an invalid key in the
// configuration.
func NewInvalidKey(t Task, key string) error {
	return &ConfigError{
		Type:     InvalidKey,
		Task:     t.Type(),
		Key:      key,
		Value:    nil,
		ShouldBe: "",
	}
}

// NewInvalidValue returns a new [ConfigError] for an invalid value in the
// configuration.
func NewInvalidValue(t Task, key string, value any) error {
	return &ConfigError{
		Type:     InvalidValue,
		Task:     t.Type(),
		Key:      key,
		Value:    value,
		ShouldBe: "",
	}
}

func NewInvalidType(t Task, key string, value any, shouldBe string) error {
	return &ConfigError{
		Type:     InvalidType,
		Task:     t.Type(),
		Key:      key,
		Value:    value,
		ShouldBe: shouldBe,
	}
}

func (e *ConfigError) Error() string {
	switch e.Type {
	case InvalidKey:
		return fmt.Sprintf("invalid key for task %s: %s", e.Task, e.Key)
	case InvalidValue:
		return fmt.Sprintf("key %s for task %s has an invalid value: %v", e.Key, e.Task, e.Value)
	case InvalidType:
		return fmt.Sprintf(
			"key %s for task %s has an invalid type with value %v, type should be %s",
			e.Key,
			e.Task,
			e.Value,
			e.ShouldBe,
		)
	default:
		return "invalid config"
	}
}
