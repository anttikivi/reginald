package plugin

import "github.com/hashicorp/go-plugin"

// Server represents a plugin server. Each plugin should create a new plugin
// server using [NewServer] and use that to execute the plugin. Server provides
// the RPC and gRPC capabilities for executing the plugin as well as the
// command-line implementation for Reginald's plugin discovery.
//
// The plugins must conform the expectation of Reginald. That is, the plugin
// discovery should be able to execute the plugin with the `--describe` flag so
// that the plugin returns the plugin implementations it provides in a
// predefined format that is handled by Server.
type Server struct {
	protocolVersion uint
	cmdPlugins      PluginSet
	taskPlugins     PluginSet
}

const (
	ProtocolVersion    uint = 1
	MagicCookieKey          = "REGINALD_PLUGIN"
	MagicCookieCommand      = "command"
	MagicCookieTask         = "task"
)

var (
	CmdHandshakeConfig = plugin.HandshakeConfig{
		ProtocolVersion:  ProtocolVersion,
		MagicCookieKey:   MagicCookieKey,
		MagicCookieValue: MagicCookieCommand,
	}
	TaskHandshakeConfig = plugin.HandshakeConfig{
		ProtocolVersion:  ProtocolVersion,
		MagicCookieKey:   MagicCookieKey,
		MagicCookieValue: MagicCookieTask,
	}
)

func NewServer() Server {
	return Server{}
}

// ServeCmd serves the given command plugins.
//
// ServeCmd doesn't return until the plugin is done being executed. Any fixable
// errors will be output to os.Stderr and the process will exit with a status
// code of 1. Serve will panic for unexpected conditions where a user's fix is
// unknown.
//
// This is the method that command plugins should call in their main()
// functions.
func ServeCmd(plugins plugin.PluginSet) {
	plugin.Serve(&plugin.ServeConfig{
		HandshakeConfig: CmdHandshakeConfig,
		Plugins:         plugins,
	})
}

// ServeTask serves the given task plugins.
//
// ServeTask doesn't return until the plugin is done being executed. Any fixable
// errors will be output to os.Stderr and the process will exit with a status
// code of 1. Serve will panic for unexpected conditions where a user's fix is
// unknown.
//
// This is the method that task plugins should call in their main() functions.
func ServeTask(plugins PluginSet) {
	// TODO: Is this hack necessary?
	set := make(map[string]plugin.Plugin)
	for k, v := range plugins {
		set[k] = plugin.Plugin(v)
	}

	plugin.Serve(&plugin.ServeConfig{
		HandshakeConfig: TaskHandshakeConfig,
		Plugins:         set,
	})
}
