package constants

import "errors"

type ContextKey string

const ConfigContextKey ContextKey = "cfg"

var ErrNoConfig = errors.New("no config instance in context")
