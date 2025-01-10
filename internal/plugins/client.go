// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugins

import (
	"errors"
	"fmt"
	"os/exec"

	rglplugin "github.com/anttikivi/reginald/pkg/plugin"
	"github.com/hashicorp/go-plugin"
)

var ErrEmptyInfo = errors.New("provided plugin info contains no commands or tasks")

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

	return *plugin.NewClient(&plugin.ClientConfig{
		HandshakeConfig: rglplugin.HandshakeConfig,
		Plugins:         pluginMap,
		Cmd:             exec.Command(info.Executable),
	}), nil
}
