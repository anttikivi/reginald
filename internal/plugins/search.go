// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package plugins

import (
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/paths"
	"github.com/anttikivi/reginald/internal/runner"
	"github.com/anttikivi/reginald/internal/ui"
	"github.com/anttikivi/reginald/pkg/plugin"
)

// PluginInfo is information on a found plugin.
type PluginInfo struct {
	Name            string
	Executable      string
	ProtocolVersion uint
	Commands        plugin.Set
	Tasks           plugin.Set
}

// discoveryConfig is the settings passed to the [discover] function during the
// plugin search.
type discoveryConfig struct {
	files   []os.DirEntry
	dir     string
	printer *ui.Printer
	run     *runner.Runner
}

// discoveryResult is the return value from [discover].
type discoveryResult struct {
	pluginInfos []PluginInfo
	err         error
}

// DefaultDir is the default search directory for plugins.
//
//nolint:gochecknoglobals // Value is used as a constant.
var DefaultDir string

// Errors returned by the plugin search.
var (
	errDirectoryInPlugins = errors.New("plugin directory entry is a directory")
	errInvalidPluginName  = errors.New("plugin name does not have the required prefix")
)

func init() { //nolint:gochecknoinits // The default directory has to be initialized.
	var (
		dir string
		err error
	)

	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome != "" {
		if dir, err = paths.Abs("${XDG_DATA_HOME}/reginald"); err != nil {
			panic(exit.New(exit.CommandInitFailure, fmt.Errorf("failed to construct absolute path: %w", err)))
		}
	}

	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			panic(exit.New(exit.CommandInitFailure, fmt.Errorf("failed to get the user home directory: %w", err)))
		}

		dir = filepath.Join(home, ".local", "share", "reginald")
	}

	DefaultDir = dir
}

// Search searches the given directory for valid plugins and returns a slice of
// [PluginInfo]s on the plugins found.
func Search(dir string, p *ui.Printer, r *runner.Runner) ([]PluginInfo, error) {
	original := dir

	dir, err := paths.Abs(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to convert %s into absolute path: %w", original, err)
	}

	slog.Info("starting the plugin discovery", "path", dir)

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

	result := ui.Spinner(p, discover, fmt.Sprintf("Searching for plugins from %s...", dir), opts)
	if result.err != nil {
		ui.Errorf(p, "The plugin search failed: %v\n", result.err)

		//nolint:nilerr // TODO: For now, the desired functionality is the continue even if plugins are not found.
		return nil, nil
	}

	return result.pluginInfos, nil
}

func discover(opts discoveryConfig) discoveryResult {
	var (
		p        = opts.printer
		plugins  = make([]PluginInfo, 0)
		pluginCh = make(chan *PluginInfo, len(opts.files))
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

	return discoveryResult{pluginInfos: plugins, err: nil}
}

func checkPath(r *runner.Runner, f os.DirEntry, dir string) (*PluginInfo, error) {
	fullPath := filepath.Join(dir, f.Name())
	slog.Debug("checking if an entry is a plugin", "name", f.Name(), "path", fullPath)

	if !strings.HasPrefix(f.Name(), "reginald-plugin-") {
		slog.Info("plugin directory entry with an invalid name", "name", f.Name(), "path", fullPath)

		return nil, fmt.Errorf("%w: %s", errInvalidPluginName, f.Name())
	}

	if f.IsDir() {
		slog.Warn("found a directory in the plugins path", "path", fullPath)

		return nil, fmt.Errorf("%w %s", errDirectoryInPlugins, fullPath)
	}

	out, err := r.Output(fullPath, "--describe")
	if err != nil {
		return nil, fmt.Errorf("failed to run the plugin executable: %w", err)
	}

	slog.Debug("ran the plugin description", "out", string(out))

	var desc plugin.Descriptor
	if err := json.Unmarshal(out, &desc); err != nil {
		return nil, fmt.Errorf("failed to unmarshal the plugin executable descriptor: %w", err)
	}

	result := &PluginInfo{
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
