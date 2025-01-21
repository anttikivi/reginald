// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package apply

import (
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"sync"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/plugins"
	"github.com/anttikivi/reginald/internal/ui"
	"github.com/anttikivi/reginald/pkg/task"
)

// taskSet contains a set of tasks. It is used for the built-in tasks of the
// program.
type taskSet map[string]task.Task

type checkOptions struct {
	printer *ui.Printer
	cfg     *config.Config
}

type checkResult struct {
	name     string
	taskType string
	err      error
}

type checkDefaultsResult struct {
	taskType string
	err      error
}

// errDuplicateNames is returned if the program encounters duplicate names while
// automatically assigning names for the tasks.
var errDuplicateNames = errors.New("two tasks were given the same name")

// errNoPlugins           = errors.New("no plugins provided")
// errInvalidPluginConfig = errors.New("invalid plugin config")

// Errors to return from checking the configs and running the task. If the
// config itself is wrong, the task's function should return [task.ConfigError].
var (
	errCheckConfigs      = errors.New("errors while checking configurations for tasks")
	errCheckDefaults     = errors.New("errors while checking default configurations for tasks")
	errInvalidTaskType   = errors.New("no task matches the given task type")
	errTaskTypeAssertion = errors.New("type assertion to task failed")
)

// builtin contains the built-in tasks of the program. The program assumes that
// rest of the tasks are found from the plugins.
//
//nolint:gochecknoglobals // Used like a constant.
var builtin = taskSet{
	"clean": &clean{},
	"link":  &link{},
}

// assignTaskNames assigns every task a unique name and returns an error if the
// user has given two tasks the same name.
func assignTaskNames(cfg *config.Config) error {
	if len(cfg.Tasks) == 0 {
		return nil
	}

	var (
		counts = make(map[string]int)
		names  = make(map[string]struct{})
	)

	for _, t := range cfg.Tasks {
		if t.Name != "" {
			if _, ok := names[t.Name]; ok {
				return fmt.Errorf("%w: %s", errDuplicateNames, t.Name)
			}

			names[t.Name] = struct{}{}

			continue
		}

		var i int
		if j, ok := counts[t.Type]; ok {
			i = j
		}

		name := fmt.Sprintf("%s-%d", t.Type, i)

		if _, ok := names[t.Name]; ok {
			i++
			name = fmt.Sprintf("%s-%d", t.Type, i)
		}

		t.Name = name

		counts[t.Type] = i
	}

	return nil
}

// mergeGlobalConfig sets the global config values required by the tasks to
// the task configs.
func mergeGlobalConfig(cfg *config.Config) *config.Config {
	for _, taskCfg := range cfg.Tasks {
		if taskCfg.Type == "link" {
			taskCfg.Settings["base-directory"] = cfg.BaseDirectory
		}
	}

	return cfg
}

// checkTaskConfigs validates the configs for each task. It returns any error
// that occurred. A nil return value means that the configs are valid.
func checkTaskConfigs(opts checkOptions) error {
	var (
		printer  = opts.printer
		infos    = opts.cfg.PluginInfos
		resultCh = make(chan checkResult)
		wg       sync.WaitGroup
	)

	for _, cfg := range opts.cfg.Tasks {
		wg.Add(1)

		go func() {
			defer wg.Done()

			slog.Debug("going to check task settings", "settings", cfg.Settings)

			if t, ok := builtin[cfg.Type]; ok {
				err := t.Check(cfg.Settings)
				resultCh <- checkResult{name: cfg.Name, taskType: cfg.Type, err: err}

				return
			}

			i := slices.IndexFunc(infos, func(info plugins.PluginInfo) bool {
				_, ok := info.Tasks[cfg.Type]

				return ok
			})

			if i == -1 {
				resultCh <- checkResult{name: cfg.Name, taskType: cfg.Type, err: errInvalidTaskType}

				return
			}

			info := infos[i]

			err := checkPlugin(info, cfg.Type, cfg.Settings)
			resultCh <- checkResult{name: cfg.Name, taskType: cfg.Type, err: err}
		}()
	}

	go func() {
		wg.Wait()
		slog.Debug("all of the task config checks are complete, closing channel")
		close(resultCh)
	}()

	var configErrs error

	for r := range resultCh {
		slog.Debug("received results for task config check", "result", r)

		if r.err != nil {
			if errors.Is(r.err, errInvalidTaskType) {
				ui.Warnf(printer, "Failed to check the configs for task %s: %v\n", r.taskType, r.err)

				continue
			}

			var cfgErr *task.ConfigError
			if errors.As(r.err, &cfgErr) {
				slog.Debug("task returned a ConfigError", "task", r.taskType, "err", cfgErr.Error())

				configErrs = errors.Join(configErrs, cfgErr)

				continue
			}

			return fmt.Errorf("failed to check the configs for task %s: %w", r.taskType, r.err)
		}
	}

	if configErrs != nil {
		var (
			s   string
			err error
		)

		if joined, ok := configErrs.(interface{ Unwrap() []error }); ok {
			for _, e := range joined.Unwrap() {
				s = fmt.Sprintf("%s\n - %v", s, e.Error())
			}
		} else {
			s = configErrs.Error()
		}

		err = fmt.Errorf("%w:%s", errCheckConfigs, s)

		return err
	}

	return nil
}

func checkPlugin(info plugins.PluginInfo, taskType string, settings task.Settings) error {
	client, err := plugins.NewClient(info)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer client.Kill()

	rpcClient, err := client.Client()
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	raw, err := rpcClient.Dispense("task-" + taskType)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	t, ok := raw.(task.Task)
	if !ok {
		return fmt.Errorf("%w: %s", errTaskTypeAssertion, taskType)
	}

	err = t.Check(settings)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// checkTaskDefaults validates the configs for each task. It returns any error
// that occurred. A nil return value means that the default configs are valid.
func checkTaskDefaults(opts checkOptions) error {
	var (
		printer  = opts.printer
		infos    = opts.cfg.PluginInfos
		defaults = opts.cfg.Defaults
		resultCh = make(chan checkDefaultsResult)
		wg       sync.WaitGroup
	)

	for key := range opts.cfg.Defaults {
		wg.Add(1)

		go func() {
			defer wg.Done()

			if t, ok := builtin[key]; ok {
				err := t.CheckDefaults(defaults[key])
				resultCh <- checkDefaultsResult{taskType: key, err: err}

				return
			}

			i := slices.IndexFunc(infos, func(info plugins.PluginInfo) bool {
				_, ok := info.Tasks[key]

				return ok
			})

			if i == -1 {
				resultCh <- checkDefaultsResult{taskType: key, err: errInvalidTaskType}

				return
			}

			info := infos[i]

			err := checkPluginDefaults(info, key, defaults[key])
			resultCh <- checkDefaultsResult{taskType: key, err: err}
		}()
	}

	go func() {
		wg.Wait()
		slog.Debug("all of the default config checks are complete, closing channel")
		close(resultCh)
	}()

	var configErrs error

	for r := range resultCh {
		slog.Debug("received results for task defaults check", "result", r)

		if r.err != nil {
			if errors.Is(r.err, errInvalidTaskType) {
				ui.Warnf(printer, "Failed to check the defaults for task %s: %v\n", r.taskType, r.err)

				continue
			}

			var cfgErr *task.ConfigError
			if errors.As(r.err, &cfgErr) {
				slog.Debug("task returned a ConfigError", "task", r.taskType, "err", cfgErr.Error())

				configErrs = errors.Join(configErrs, cfgErr)

				continue
			}

			return fmt.Errorf("failed to check the defaults for task %s: %w", r.taskType, r.err)
		}
	}

	if configErrs != nil {
		var (
			s   string
			err error
		)

		if joined, ok := configErrs.(interface{ Unwrap() []error }); ok {
			for _, e := range joined.Unwrap() {
				s = fmt.Sprintf("%s\n - %v", s, e.Error())
			}
		} else {
			s = configErrs.Error()
		}

		err = fmt.Errorf("%w:%s", errCheckDefaults, s)

		return err
	}

	return nil
}

func checkPluginDefaults(info plugins.PluginInfo, taskType string, settings task.Settings) error {
	client, err := plugins.NewClient(info)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer client.Kill()

	rpcClient, err := client.Client()
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	raw, err := rpcClient.Dispense("task-" + taskType)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	t, ok := raw.(task.Task)
	if !ok {
		return fmt.Errorf("%w: %s", errTaskTypeAssertion, taskType)
	}

	err = t.CheckDefaults(settings)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// mergeDefaults merges the defaults for tasks into the task configs.
func mergeDefaults(cfg *config.Config) *config.Config {
	modified := make(task.ConfigList, len(cfg.Tasks))

	for taskName, settings := range cfg.Defaults {
		for i, t := range cfg.Tasks {
			if taskName != t.Type {
				continue
			}

			for k, v := range settings {
				if _, ok := t.Settings[k]; !ok {
					t.Settings[k] = v
				}
			}

			modified[i] = t
		}
	}

	result := make(task.ConfigList, len(cfg.Tasks))

	for i, t := range modified {
		if t == nil {
			result[i] = cfg.Tasks[i]
		} else {
			result[i] = t
		}
	}

	cfg.Tasks = result

	return cfg
}

func runTasks(_ *ui.Printer, cfg *config.Config) error {
	slog.Info("starting to run the tasks")

	for _, taskCfg := range cfg.Tasks {
		slog.Info("handling task", "task", taskCfg.Name, "type", taskCfg.Type)

		if t, ok := builtin[taskCfg.Type]; ok {
			slog.Debug("running from built-in tasks", "task", taskCfg.Name, "type", taskCfg.Type)

			if err := t.Run(taskCfg); err != nil {
				return fmt.Errorf("running task %s failed: %w", taskCfg.Name, err)
			}

			continue
		}

		i := slices.IndexFunc(cfg.PluginInfos, func(info plugins.PluginInfo) bool {
			_, ok := info.Tasks[taskCfg.Type]

			return ok
		})

		if i == -1 {
			return fmt.Errorf("running task %s failed: %w %s", taskCfg.Name, errInvalidTaskType, taskCfg.Type)
		}

		info := cfg.PluginInfos[i]

		slog.Debug("running task from plugin", "plugin", info.Name, "task", taskCfg.Name, "type", taskCfg.Type)

		if err := runPluginTask(info, taskCfg); err != nil {
			return fmt.Errorf("running task %s failed: %w", taskCfg.Name, err)
		}
	}

	slog.Info("successfully ran the tasks")

	return nil
}

func runPluginTask(info plugins.PluginInfo, cfg *task.Config) error {
	client, err := plugins.NewClient(info)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer client.Kill()

	rpcClient, err := client.Client()
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	raw, err := rpcClient.Dispense("task-" + cfg.Type)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	t, ok := raw.(task.Task)
	if !ok {
		return fmt.Errorf("%w: %s", errTaskTypeAssertion, cfg.Type)
	}

	err = t.Run(cfg)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}
