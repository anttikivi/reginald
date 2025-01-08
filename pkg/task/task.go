package task

import (
	"net/rpc"

	"github.com/hashicorp/go-plugin"
)

// Task is a task that Reginald can run.
//
// Some of the most common tasks, like installing packages and creating the symbolic links
type Task interface {
	Run() error
}

type TaskRPC struct {
	client *rpc.Client
}

type TaskRPCServer struct {
	Impl Task
}

// TaskPlugin is an implementation of task plugins. It is used for serving and
// consuming a task plugin.
type TaskPlugin struct {
	Impl Task
}

func (t *TaskRPC) Run() error {
	var res error
	err := t.client.Call("Plugin.Run", new(any), &res)
	if err != nil {
		panic(err)
	}

	return nil
}

func (s *TaskRPCServer) Run(args any, res *error) error {
	*res = s.Impl.Run()

	return nil
}

func (p *TaskPlugin) Server(_ *plugin.MuxBroker) (any, error) {
	return &TaskRPCServer{Impl: p.Impl}, nil
}

func (p *TaskPlugin) Client(_ *plugin.MuxBroker, c *rpc.Client) (any, error) {
	return &TaskRPC{client: c}, nil
}
