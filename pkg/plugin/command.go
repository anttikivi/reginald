// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugin

import (
	"net/rpc"

	"github.com/anttikivi/reginald/pkg/command"
	"github.com/hashicorp/go-plugin"
)

// CmdRPC is a [command.Command] implementation that talks over RPC. It is the
// client that consumes a plugin. The RPC client can be obtained with
// [CmdPlugin.Client].
type CmdRPC struct {
	client *rpc.Client
}

// CmdRPCServer is a [command.Command] implementation used on the RPC server
// (the plugin) that the client-side [CmdRPC] talks to over RPC. The RPC server
// can be obtained with [CmdPlugin.Server].
type CmdRPCServer struct {
	Impl command.Command
}

// CmdPlugin is the implementation of [Plugin] for commands. It is used for
// serving and consuming a command plugin.
//
// To serve a command given as Impl from a plugin, use the [CmdPlugin.Server]
// function to get the RPC server. It contructs and serves a [CmdRPCServer].
//
// To consume a command as a client from a plugin, use the [CmdPlugin.Client]
// function to get the RPC client. It contructs and serves a [CmdRPC].
type CmdPlugin struct {
	Impl command.Command
}

func (c *CmdRPC) Name() string {
	var resp string

	if err := c.client.Call("Plugin.Name", new(any), &resp); err != nil {
		panic(err)
	}

	return resp
}

func (c *CmdRPC) Run() error {
	var resp error

	if err := c.client.Call("Plugin.Run", new(any), &resp); err != nil {
		panic(err)
	}

	return resp
}

func (s *CmdRPCServer) Name(_ any, resp *string) error {
	*resp = s.Impl.Name()

	return nil
}

func (s *CmdRPCServer) Run(_ any, resp *error) error { //nolint:gocritic // `resp` has to be pointer for RCP.
	*resp = s.Impl.Run()

	return nil
}

// Server returns the server implementation of [command.Command] for the
// [CmdPlugin].
func (p *CmdPlugin) Server(_ *plugin.MuxBroker) (any, error) {
	return &CmdRPCServer{Impl: p.Impl}, nil
}

// Client returns the client implementation of [command.Command] for the
// [CmdPlugin].
func (p *CmdPlugin) Client(_ *plugin.MuxBroker, c *rpc.Client) (any, error) {
	return &CmdRPC{client: c}, nil
}
