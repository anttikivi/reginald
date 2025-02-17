// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	moduleName   = "github.com/anttikivi/reginald"
	pluginsDir   = "./plugins"
	pluginsDest  = "./share/reginald"
	pluginPrefix = "reginald-plugin-"
)

var tasks = map[string]func(string) error{ //nolint:gochecknoglobals // tasks can as well be global, we don't modify it
	"bin/reginald": func(exe string) error {
		skipped := []string{
			"bin",
			"plugins",
			"share",
		}

		info, err := os.Stat(exe)
		if err == nil && !sourceFilesLaterThan(info.ModTime(), skipped, nil) {
			fmt.Fprintf(os.Stdout, "%s: `%s` is up to date.\n", self, exe)

			return nil
		}

		ldflags := os.Getenv("GO_LDFLAGS")
		ldflags = fmt.Sprintf("-X %s/internal/build.Version=%s %s", moduleName, version(), ldflags)
		ldflags = fmt.Sprintf("-X %s/internal/build.Date=%s %s", moduleName, date(), ldflags)

		return run("go", "build", "-trimpath", "-ldflags", ldflags, "-o", exe, ".")
	},
	"clean": func(_ string) error {
		return rmrf("bin", "share")
	},
	"man": func(_ string) error {
		return run("go", "run", "./cmd/docs", "--man", "--path", "./share/man/man1/")
	},
	"plugins": func(_ string) error {
		files, err := os.ReadDir("./plugins")
		if err != nil {
			return fmt.Errorf("failed to read the directory ./plugins: %w", err)
		}

		for _, f := range files {
			if f.IsDir() {
				err := buildPlugin(f.Name())
				if err != nil {
					return fmt.Errorf("failed to build plugin/%s: %w", f.Name(), err)
				}
			}
		}

		return nil
	},
	"plugin": buildPlugin,
}

var self string //nolint:gochecknoglobals // Self is shared within this script.

func main() {
	args := os.Args[:1]

	for _, arg := range os.Args[1:] {
		if idx := strings.IndexRune(arg, '='); idx >= 0 {
			os.Setenv(arg[:idx], arg[idx+1:])
		} else {
			args = append(args, arg)
		}
	}

	if len(args) < 2 { //nolint:mnd // Args contains only the name of this script.
		if isWindowsTarget() {
			args = append(args, filepath.Join("bin", "reggie.exe"))
		} else {
			args = append(args, "bin/reggie")
		}
	}

	self = filepath.Base(args[0])
	if self == "build" {
		self = "build.go"
	}

	for _, task := range args[1:] {
		tn := normalizeTask(task)
		t := tasks[tn]

		// Include "plugin" here to catch invalid call straight to the "plugin"
		// task. The full name must be used in order to build the correct
		// plugin.
		if t == nil || task == "plugin" {
			fmt.Fprintf(os.Stderr, "Don't know how to build task `%s`.\n", task)
			os.Exit(1)
		}

		var err error

		if tn == "plugin" {
			err = t(strings.TrimPrefix(task, "plugin/"))
		} else {
			err = t(task)
		}

		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			fmt.Fprintf(os.Stderr, "%s: building task `%s` failed.\n", self, task)
			os.Exit(1)
		}
	}
}

func isWindowsTarget() bool {
	if os.Getenv("GOOS") == "windows" {
		return true
	}

	if runtime.GOOS == "windows" {
		return true
	}

	return false
}

func version() string {
	if versionEnv := os.Getenv("REGINALD_VERSION"); versionEnv != "" {
		return versionEnv
	}

	if desc, err := cmdOutput("git", "describe", "--tags"); err == nil {
		return desc
	}

	rev, _ := cmdOutput("git", "rev-parse", "--short", "HEAD")

	return rev
}

func date() string {
	t := time.Now()

	if sourceDate := os.Getenv("SOURCE_DATE_EPOCH"); sourceDate != "" {
		if sec, err := strconv.ParseInt(sourceDate, 10, 64); err == nil {
			t = time.Unix(sec, 0)
		}
	}

	return t.Format("2006-01-02")
}

// sourceFilesLaterThan checks if the project files have been modified since the
// given time t. If exclude is given and is not nil, the given files and
// directories will be excluded. If include is given and is not nil, only the
// given files and directoies are checked.
//
//nolint:cyclop,gocognit,varnamelen // t is good enough, and there is no need to simplify the function.
func sourceFilesLaterThan(t time.Time, exclude, include []string) bool {
	foundLater := false

	err := filepath.Walk(".", func(path string, info os.FileInfo, err error) error {
		if err != nil {
			// Ignore errors that occur when the project contains a symlink to
			// a filesystem or volume that Windows doesn't have access to.
			if path != "." && isAccessDenied(err) {
				fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)

				return nil
			}

			return err
		}

		if foundLater {
			return filepath.SkipDir
		}

		if len(path) > 1 && (path[0] == '.' || path[0] == '_') {
			if info.IsDir() {
				return filepath.SkipDir
			}

			return nil
		}

		if include != nil && path != "." && info.IsDir() && !slices.ContainsFunc(include, func(s string) bool {
			return path == s || strings.HasPrefix(path, s)
		}) {
			return filepath.SkipDir
		}

		if slices.Contains(exclude, path) {
			return filepath.SkipDir
		}

		if info.IsDir() {
			if name := filepath.Base(path); name == "vendor" || name == "node_modules" {
				return filepath.SkipDir
			}

			return nil
		}

		if path == "go.mod" || path == "go.sum" ||
			(strings.HasSuffix(path, ".go") && !strings.HasSuffix(path, "_test.go")) {
			if info.ModTime().After(t) {
				foundLater = true
			}
		}

		return nil
	})
	if err != nil {
		panic(err)
	}

	return foundLater
}

func isAccessDenied(err error) bool {
	var pe *os.PathError
	// We would use `syscall.ERROR_ACCESS_DENIED` if this script supported build
	// tags.
	return errors.As(err, &pe) && strings.Contains(pe.Err.Error(), "Access is denied")
}

func shellInspect(args []string) string {
	fmtArgs := make([]string, len(args))

	for i, arg := range args {
		if strings.ContainsAny(arg, " \t'\"") {
			fmtArgs[i] = fmt.Sprintf("%q", arg)
		} else {
			fmtArgs[i] = arg
		}
	}

	return strings.Join(fmtArgs, " ")
}

func announce(args ...string) {
	fmt.Fprintln(os.Stdout, shellInspect(args))
}

func rmrf(targets ...string) error {
	args := append([]string{"rm", "-rf"}, targets...)

	announce(args...)

	for _, target := range targets {
		if err := os.RemoveAll(target); err != nil {
			return fmt.Errorf("%w", err)
		}
	}

	return nil
}

func cmdOutput(args ...string) (string, error) {
	exe, err := exec.LookPath(args[0])
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}

	cmd := exec.Command(exe, args[1:]...)
	cmd.Stderr = io.Discard
	out, err := cmd.Output()

	return strings.TrimSuffix(string(out), "\n"), err
}

// normalizeTask normalizes the task name to match the tasks in the map.
// This allows to have `.exe` at the end of the executable and specify a
// different name for the executable in the Makefile, if desired.
func normalizeTask(t string) string {
	tn := filepath.ToSlash(strings.TrimSuffix(t, ".exe"))
	if tn != "bin/reginald" && strings.HasPrefix(tn, "bin/") {
		return "bin/reginald"
	}

	if strings.HasPrefix(tn, "plugin/") {
		return "plugin"
	}

	return tn
}

func run(args ...string) error {
	exe, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	announce(args...)
	cmd := exec.Command(exe, args[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func buildPlugin(name string) error {
	name = strings.TrimPrefix(name, "plugins/")

	_, err := os.ReadDir(filepath.Join(pluginsDir, name))
	if err != nil {
		return fmt.Errorf("failed to read the directory ./plugins/%s: %w", name, err)
	}

	destDir, err := filepath.Abs(pluginsDest)
	if err != nil {
		return fmt.Errorf("failed to make the destination directory absolute: %w", err)
	}

	srcDir := strings.TrimPrefix(pluginsDir, "./") + "/" + name
	include := []string{
		"pkg",
		"plugins",
		srcDir,
		"scripts",
	}
	exe := filepath.Join(destDir, pluginPrefix+name)

	if isWindowsTarget() {
		exe += ".exe"
	}

	info, err := os.Stat(exe)
	if err == nil && !sourceFilesLaterThan(info.ModTime(), nil, include) {
		fmt.Fprintf(os.Stdout, "%s: `%s` is up to date.\n", self, exe)

		return nil
	}

	srcDir = "./" + filepath.Join(pluginsDir, name)

	// TODO: Implement date and version similar to the main executable.
	ldflags := os.Getenv("GO_LDFLAGS")

	return run("go", "build", "-trimpath", "-ldflags", ldflags, "-o", exe, srcDir)
}
