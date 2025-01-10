// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugin

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/anttikivi/reginald/internal/paths"
	"github.com/anttikivi/reginald/internal/runner"
	"github.com/anttikivi/reginald/internal/ui"
	"github.com/anttikivi/reginald/pkg/plugin"
)

type Plugin struct {
	Name            string
	Executable      string
	ProtocolVersion uint
	Commands        plugin.Set
	Tasks           plugin.Set
}

type PluginsInfo []Plugin

type discoveryConfig struct {
	files   []os.DirEntry
	dir     string
	printer *ui.Printer
	run     *runner.Runner
}

var (
	errDirectoryInPlugins = errors.New("plugin directory entry is a directory")
	errInvalidPluginName  = errors.New("plugin name does not have the required prefix")
)

func Search(dir string, p *ui.Printer, r *runner.Runner) (PluginsInfo, error) {
	original := dir

	dir, err := paths.Abs(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to convert %s into absolute path: %w", original, err)
	}

	slog.Info("Starting the plugin discovery", "path", dir)

	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to read the directory %s: %w", dir, err)
	}

	opts := discoveryConfig{
		files:   files,
		dir:     dir,
		printer: p,
		run:     r,
	}

	plugins, err := ui.Spinner(p, discover, fmt.Sprintf("Searching for plugins from %s...", dir), opts)
	if err != nil {
		ui.Errorf(p, "The plugin search failed: %v\n", err)

		return nil, nil
	}

	return plugins, nil
}

func discover(opts discoveryConfig) (PluginsInfo, error) {
	var (
		p        = opts.printer
		plugins  = make(PluginsInfo, 0)
		pluginCh = make(chan *Plugin, len(opts.files))
		wg       sync.WaitGroup
	)

	for _, f := range opts.files {
		wg.Add(1)

		go func() {
			defer wg.Done()

			plug, err := checkPath(opts.run, f, opts.dir)
			if err != nil {
				switch {
				case errors.Is(err, errInvalidPluginName):
					ui.Vwarnf(
						p,
						"Found a file in the plugins directory with an invalid name: %s\n",
						filepath.Join(opts.dir, f.Name()),
					)
				case errors.Is(err, errDirectoryInPlugins):
					ui.Vwarnf(p, "Found a directory in the plugins path: %s\n", filepath.Join(opts.dir, f.Name()))
				default:
					ui.Verrorf(
						p,
						"Error while processing the plugin at %s: %v\n",
						filepath.Join(opts.dir, f.Name()),
						err,
					)
				}

				pluginCh <- nil

				return
			}

			pluginCh <- plug
		}()
	}

	go func() {
		wg.Wait()
		close(pluginCh)
	}()

	for plugin := range pluginCh {
		if plugin != nil {
			plugins = append(plugins, *plugin)
		}
	}

	return plugins, nil
}

func checkPath(r *runner.Runner, f os.DirEntry, dir string) (*Plugin, error) {
	fullPath := filepath.Join(dir, f.Name())
	slog.Debug("Checking if an entry is a plugin", "name", f.Name(), "path", fullPath)

	if !strings.HasPrefix(f.Name(), "reginald-plugin-") {
		slog.Info("Plugin directory entry with an invalid name", "name", f.Name(), "path", fullPath)

		return nil, fmt.Errorf("%w: %s", errInvalidPluginName, f.Name())
	}

	if f.IsDir() {
		slog.Warn("Found a directory in the plugins path", "path", fullPath)

		return nil, fmt.Errorf("%w %s", errDirectoryInPlugins, fullPath)
	}

	out, err := r.Output(fullPath, "--describe")
	if err != nil {
		return nil, fmt.Errorf("failed to run the plugin executable: %w", err)
	}

	var desc plugin.Descriptor
	if err := json.Unmarshal(out, &desc); err != nil {
		return nil, fmt.Errorf("failed to unmarshal the plugin executable descriptor: %w", err)
	}

	result := &Plugin{
		Name:            desc.Name,
		Executable:      fullPath,
		ProtocolVersion: desc.ProtocolVersion,
		Commands:        nil,
		Tasks:           nil,
	}

	if len(desc.Commands) > 0 {
		result.Commands = make(plugin.Set)

		for _, s := range desc.Commands {
			result.Commands[s] = &plugin.CmdPlugin{} //nolint:exhaustruct // No need for the implementation.
		}
	}

	if len(desc.Tasks) > 0 {
		result.Tasks = make(plugin.Set)

		for _, s := range desc.Tasks {
			result.Tasks[s] = &plugin.TaskPlugin{} //nolint:exhaustruct // No need for the implementation.
		}
	}

	return result, nil
}
