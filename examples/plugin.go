// Copyright 2025 Antti Kivi
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Package main defines an example plugin for Reginald using the provided Go
// functions and types.
package main

import (
	"errors"
	"fmt"
	"os"
	"slices"
	"time"

	"github.com/reginald-project/reginald/pkg/rpp"
	"github.com/reginald-project/reginald/pkg/rpp/plugin"
)

var errInvalidConfig = errors.New("invalid config")

// EchoTask is the task implementation for the task type echo in this plugin.
type EchoTask struct{}

// SleepCommand is the command implementation for the sleep plugin.
type SleepCommand struct{}

// Type returns the name of the task type as it should be written by the user
// when they specify it in, for example, their configuration. It must not match
// any existing tasks either within Reginald or other plugins.
func (*EchoTask) Type() string {
	return "echo"
}

// Validate runs the validation of the config for the matching task type. Only
// the actual task options are checked as the ID, type, and dependencies are
// validated by Reginald.
func (*EchoTask) Validate(cfg []rpp.KeyValue) error {
	for _, c := range cfg {
		if c.Key != "msg" {
			return fmt.Errorf("%w: unknown key %q", errInvalidConfig, c.Key)
		}

		if c.Type != rpp.StringValue {
			return fmt.Errorf("%w: invalid value for %q: %q", errInvalidConfig, c.Key, c.Type)
		}
	}

	return nil
}

// Run runs this task. In the function call, dir will be the base directory of
// the Reginald run and cfg contains the configuration options for this task.
func (*EchoTask) Run(_ string, cfg []rpp.KeyValue) error {
	i := slices.IndexFunc(cfg, func(kv rpp.KeyValue) bool {
		return kv.Key == "msg"
	})
	msg := cfg[i]

	if msg.Type != rpp.StringValue {
		return fmt.Errorf("%w: invalid value for %q: %q", errInvalidConfig, msg.Key, msg.Type)
	}

	s, err := msg.String()
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if _, err = fmt.Fprintln(os.Stderr, s); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// Name returns the name of the command as it should be written by the user when
// they run the command. It must not match any existing commands either within
// Reginald or other plugins.
func (*SleepCommand) Name() string {
	return "sleep"
}

// UsageLine returns the one-line usage synopsis for the command. It should
// start with the command name.
func (*SleepCommand) UsageLine() string {
	return "sleep [options]"
}

// Configs returns the config entries of s.
func (*SleepCommand) Configs() []rpp.ConfigEntry {
	return []rpp.ConfigEntry{
		{ //nolint:exhaustruct // use the default values
			KeyValue: rpp.KeyValue{
				Key:   "time",
				Value: 5, //nolint:mnd // default value of 5s
				Type:  rpp.IntValue,
			},
			Flag: rpp.Flag{ //nolint:exhaustruct // use the default values
				Shorthand: "t",
				Usage:     "time to sleep in seconds (default 5s)",
			},
		},
	}
}

// Run executes the command for the plugin.
func (*SleepCommand) Run(cfg []rpp.ConfigEntry) error {
	var (
		err error
		t   int
	)

	for _, c := range cfg {
		if c.Key == "time" {
			t, err = c.Int()
			if err != nil {
				return fmt.Errorf("failed to get config value \"time\": %w", err)
			}
		}
	}

	fmt.Fprintf(os.Stderr, "Sleeping for %ds\n", t)
	time.Sleep(time.Duration(t) * time.Second)

	return nil
}

func main() {
	p := plugin.New("example", "0.1.0-0.dev", &EchoTask{}, &SleepCommand{})

	if err := p.Serve(); err != nil {
		fmt.Fprintf(os.Stderr, "plugin %q is going to exit with an error: %v", "sleep", err)
		os.Exit(1)
	}
}
