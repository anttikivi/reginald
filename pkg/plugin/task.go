// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

//nolint:dupl // Task and command need to be separate but duplicate.
package plugin

import (
	"net/rpc"

	"github.com/anttikivi/reginald/pkg/task"
	"github.com/hashicorp/go-plugin"
)

// TaskRPC is a [task.Task] implementation that talks over RPC. It is the client
// that consumes a plugin. The RPC client can be obtained with
// [TaskPlugin.Client].
type TaskRPC struct {
	client *rpc.Client
}

// TaskRPCServer is a [task.Task] implementation used on the RPC server (the
// plugin) that the client-side [TaskRPC] talks to over RPC. The RPC server can
// be obtained with [TaskPlugin.Server].
type TaskRPCServer struct {
	Impl task.Task
}

// TaskPlugin is the implementation of [Plugin] for tasks. It is used for
// serving and consuming a task plugin.
//
// To serve a task given as Impl from a plugin, use the [TaskPlugin.Server]
// function to get the RPC server. It contructs and serves a [TaskRPCServer].
//
// To consume a task as a client from a plugin, use the [TaskPlugin.Client]
// function to get the RPC client. It contructs and serves a [TaskRPC].
type TaskPlugin struct {
	Impl task.Task
}

func (t *TaskRPC) Name() string {
	var resp string

	if err := t.client.Call("Plugin.Name", new(any), &resp); err != nil {
		panic(err)
	}

	return resp
}

func (t *TaskRPC) Run() error {
	var resp error

	if err := t.client.Call("Plugin.Run", new(any), &resp); err != nil {
		panic(err)
	}

	return resp
}

func (s *TaskRPCServer) Name(_ any, resp *string) error {
	*resp = s.Impl.Name()

	return nil
}

func (s *TaskRPCServer) Run(_ any, resp *error) error { //nolint:gocritic // `resp` has to be pointer for RCP.
	*resp = s.Impl.Run()

	return nil
}

// Server returns the server implementation of [task.Task] for the [TaskPlugin].
func (p *TaskPlugin) Server(_ *plugin.MuxBroker) (any, error) {
	return &TaskRPCServer{Impl: p.Impl}, nil
}

// Client returns the client implementation of [task.Task] for the [TaskPlugin].
func (p *TaskPlugin) Client(_ *plugin.MuxBroker, c *rpc.Client) (any, error) {
	return &TaskRPC{client: c}, nil
}
