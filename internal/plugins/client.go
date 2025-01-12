// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugins

import (
	"encoding/gob"
	"errors"
	"fmt"
	"log/slog"
	"os/exec"

	"github.com/anttikivi/reginald/internal/logging"
	rglplugin "github.com/anttikivi/reginald/pkg/plugin"
	"github.com/anttikivi/reginald/pkg/task"
	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/go-plugin"
)

// registerTask is a helper type used while registering [task.Config] for binary
// exchange.
type registerTask struct{}

var ErrEmptyInfo = errors.New("provided plugin info contains no commands or tasks")

func init() { //nolint:gochecknoinits // The binary values must be registered once, and, thus, we use init here.
	gob.Register(task.NewInvalidType(&registerTask{}, "key", "value", "type"))
}

// NewClient provides a new plugin client for the given [PluginInfo]. It returns
// an error if the PluginInfo contains no commands or tasks.
//
// The caller of the function must call [plugin.Client.Kill] after using the
// client.
func NewClient(info PluginInfo) (plugin.Client, error) {
	var pluginMap plugin.PluginSet

	if len(info.Commands) > 0 {
		pluginMap = make(plugin.PluginSet)

		for k, v := range info.Commands {
			pluginMap["cmd-"+k] = v
		}
	}

	if len(info.Tasks) > 0 {
		if pluginMap == nil {
			pluginMap = make(plugin.PluginSet)
		}

		for k, v := range info.Tasks {
			pluginMap["task-"+k] = v
		}
	}

	if pluginMap == nil {
		return plugin.Client{}, fmt.Errorf("%w: %s", ErrEmptyInfo, info.Name)
	}

	hclog.SetDefault(logging.NewSlogAdapter(slog.Default(), slog.LevelDebug, "plugin"))

	return *plugin.NewClient(&plugin.ClientConfig{ //nolint:exhaustruct // We want to use the default values.
		HandshakeConfig: rglplugin.HandshakeConfig,
		Plugins:         pluginMap,
		Cmd:             exec.Command(info.Executable), //nolint:gosec // G204: the path is set within the program.
		Logger:          hclog.Default(),
	}), nil
}

func (t *registerTask) Check(_ task.Settings) error {
	return nil
}

func (t *registerTask) CheckDefaults(_ task.Settings) error {
	return nil
}

func (t *registerTask) Run(_ *task.Config) error {
	return nil
}

func (t *registerTask) Type() string {
	return "for-register"
}
