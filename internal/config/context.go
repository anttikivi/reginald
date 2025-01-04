package config

import "errors"

type ContextKey string

const (
	// ConfigContextKey is the key for the config instance in the command
	// context.
	ConfigContextKey ContextKey = "cfg"

	// ViperContextKey is the key for the Viper instance in the command context.
	ViperContextKey ContextKey = "viper"
)

var (
	ErrNoConfig = errors.New("no config instance in context")
	ErrNoViper  = errors.New("no Viper instance in context")
)
