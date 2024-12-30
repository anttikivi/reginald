package config

import (
	"errors"

	"github.com/spf13/viper"
)

type ContextKey string

const ConfigContextKey ContextKey = "cfg" //nolint:decorder // weird in this case

var ErrNoConfig = errors.New("no config instance in context") //nolint:decorder // weird in this case

func New() *viper.Viper {
	return viper.New()
}
