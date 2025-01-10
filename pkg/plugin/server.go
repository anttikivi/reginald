// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugin

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/anttikivi/reginald/pkg/command"
	"github.com/anttikivi/reginald/pkg/task"
	"github.com/hashicorp/go-plugin"
)

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
	name            string
	protocolVersion uint
	cmds            []command.Command
	tasks           []task.Task
}

// Descriptor describes the plugin when Reginald request for information on the
// plugins during discovery.
type Descriptor struct {
	Name            string   `json:"name"`            // name of the plugin
	ProtocolVersion uint     `json:"protocolVersion"` // protocol version used by plugin
	Commands        []string `json:"commands"`        // commands the plugin provided, can be empty or nil
	Tasks           []string `json:"tasks"`           // tasks the plugin provided, can be empty or nil
}

// Helper values for creating the handshake configuration for the plugin server.
const (
	ProtocolVersion uint = 1
	MagicCookieKey       = "REGINALD_PLUGIN"
	MagicCookie          = "plugin"
)

// Exit codes for the `--describe` functionality of the plugin server
// executable.
const (
	ExitSuccess      = 0
	ExitMarshalError = 2 // marshaling the descriptor failed
)

// Set handshake configs for the plugin servers and clients.
var HandshakeConfig = plugin.HandshakeConfig{ //nolint:gochecknoglobals // Used like a constant.
	ProtocolVersion:  ProtocolVersion,
	MagicCookieKey:   MagicCookieKey,
	MagicCookieValue: MagicCookie,
}

var ErrEmptyPlugin = errors.New("plugin specified no commands or tasks")

// NewServer returns a new plugins server. You can pass the commands and tasks
// this plugin serves as parameters. If the plugin only serves the other, you
// can pass a nil [PluginSet] to the other parameter.
func NewServer(name string, cmds []command.Command, tasks []task.Task) Server {
	return Server{
		name:            name,
		protocolVersion: ProtocolVersion,
		cmds:            cmds,
		tasks:           tasks,
	}
}

func NewCommandServer(name string, cmds []command.Command) Server {
	return NewServer(name, cmds, nil)
}

func NewTaskServer(name string, tasks []task.Task) Server {
	return NewServer(name, nil, tasks)
}

func (s *Server) Describe() {
	if len(os.Args) <= 1 {
		return
	}

	describe := flag.Bool("describe", false, "output information on this plugin")
	flag.Parse()

	if !*describe {
		return
	}

	var (
		cmds  = make([]string, 0, len(s.cmds))
		tasks = make([]string, 0, len(s.tasks))
	)

	if len(s.cmds) > 0 {
		for _, c := range s.cmds {
			cmds = append(cmds, c.Name())
		}
	}

	if len(s.tasks) > 0 {
		for _, t := range s.tasks {
			tasks = append(tasks, t.Name())
		}
	}

	desc := Descriptor{
		Name:            s.name,
		ProtocolVersion: s.protocolVersion,
		Commands:        cmds,
		Tasks:           tasks,
	}

	out, err := json.Marshal(desc)
	if err != nil {
		fmt.Fprintf(os.Stdout, "{\"err\":\"%v\"}", err)
		os.Exit(ExitMarshalError)
	}

	fmt.Fprint(os.Stdout, string(out))
	os.Exit(0)
}

func (s *Server) Serve() error {
	var plugins plugin.PluginSet

	if len(s.cmds) > 0 {
		plugins = plugin.PluginSet{}

		for _, c := range s.cmds {
			plugins["cmd-"+c.Name()] = &CmdPlugin{Impl: c}
		}
	}

	if len(s.cmds) > 0 {
		if plugins == nil {
			plugins = plugin.PluginSet{}
		}

		for _, t := range s.tasks {
			plugins["task-"+t.Name()] = &TaskPlugin{Impl: t}
		}
	}

	if plugins == nil {
		return fmt.Errorf("failed to serve %s: %w", s.name, ErrEmptyPlugin)
	}

	plugin.Serve(&plugin.ServeConfig{ //nolint:exhaustruct // We use the default values.
		HandshakeConfig: HandshakeConfig,
		Plugins:         plugins,
	})

	return nil
}
