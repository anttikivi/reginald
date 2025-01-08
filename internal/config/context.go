// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package config

import "errors"

// ContextKey is a key that is used with the command context within the program
// to handle values associated with the context.
type ContextKey string

// Context keys that are used with the command context to store and get values.
const (
	ConfigContextKey  ContextKey = "cfg"     // key for the parsed config instance
	PrinterContextKey ContextKey = "printer" // key for the printer instance
	RunnerContextKey  ContextKey = "runner"  // key for the runner instance
	ViperContextKey   ContextKey = "viper"   // key for the Viper instance used to parse the configuration
)

var (
	ErrNoConfig  = errors.New("no config instance in context")
	ErrNoPrinter = errors.New("no printer instance in context")
	ErrNoRunner  = errors.New("no runner instance in context")
	ErrNoViper   = errors.New("no Viper instance in context")
)
