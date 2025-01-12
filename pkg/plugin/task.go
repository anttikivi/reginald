// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugin

import (
	"fmt"
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

func (t *TaskRPC) Check(settings task.Settings) error {
	var resp error

	if err := t.client.Call("Plugin.Check", settings, &resp); err != nil {
		return fmt.Errorf("%w", err)
	}

	return resp
}

func (t *TaskRPC) CheckDefaults(settings task.Settings) error {
	var resp error

	if err := t.client.Call("Plugin.CheckDefaults", settings, &resp); err != nil {
		return fmt.Errorf("%w", err)
	}

	return resp
}

func (t *TaskRPC) Run(cfg *task.Config) error {
	var resp any

	if err := t.client.Call("Plugin.Run", cfg, &resp); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func (t *TaskRPC) Type() string {
	var resp string

	if err := t.client.Call("Plugin.Type", new(any), &resp); err != nil {
		panic(err)
	}

	return resp
}

//nolint:gocritic // `resp` needs to be a pointer for the RPC implementation.
func (s *TaskRPCServer) Check(settings task.Settings, resp *error) error {
	*resp = s.Impl.Check(settings)

	return nil
}

//nolint:gocritic // `resp` needs to be a pointer for the RPC implementation.
func (s *TaskRPCServer) CheckDefaults(settings task.Settings, resp *error) error {
	*resp = s.Impl.CheckDefaults(settings)

	return nil
}

//nolint:gocritic // `resp` needs to be a pointer for the RPC implementation.
func (s *TaskRPCServer) Run(cfg *task.Config, resp *any) error { //nolint:revive // TODO: `resp` will be needed.
	if err := s.Impl.Run(cfg); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func (s *TaskRPCServer) Type(_ any, resp *string) error {
	*resp = s.Impl.Type()

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
