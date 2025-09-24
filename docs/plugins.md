# Reginald Plugins

Reginald can be extended with plugins that can define arbitrary commands and
tasks. In the current plugin system, each plugin is an executable that is
started by Reginald and that communicates with Reginald with JSON-RPC 2.0. Each
plugin must also include a manifest file that contains the information that is
required for starting up the plugin executable. This document describes the
structure of the plugins and the communication protocol that the plugins and
Reginald use.

## Plugin lookup and structure
