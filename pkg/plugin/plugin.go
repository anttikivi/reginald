// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugin

import "github.com/hashicorp/go-plugin"

// Plugin is an alias for the [plugin.Plugin] interface used in the
// implementation of Reginald plugins. It is implemented to serve and consume
// plugins.
type Plugin = plugin.Plugin

// Set is a set of plugins provided to be registered in the plugin server.
type Set map[string]Plugin
