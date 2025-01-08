// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugin

import "github.com/hashicorp/go-plugin"

// Plugin is an alias for the [plugin.Plugin] interface used in the
// implementation of Reginald plugins. It is implemented to serve and consume
// plugins.
type Plugin = plugin.Plugin

// PluginSet is a set of plugins provided to be registered in the plugin server.
type PluginSet map[string]Plugin

// PluginType represents the type of the plugin.
type PluginType byte

// PluginTypeNone is the base plugin type. If the plugin gives this as its
// plugin type, it is ignored during the plugin discovery.
const PluginTypeNone PluginType = 0

// The plugin type to use with plugins. The plugin types can be combined using
// the OR operator.
const (
	PluginTypeCommand PluginType = 1 << iota
	PluginTypeTask
)

// IsCommand reports whether the [PluginType] represents a plugin that offers a
// command plugin.
func (t PluginType) IsCommand() bool {
	return t&PluginTypeCommand != 0
}

// IsTask reports whether the [PluginType] represents a plugin that offers a
// task plugin.
func (t PluginType) IsTask() bool {
	return t&PluginTypeTask != 0
}
