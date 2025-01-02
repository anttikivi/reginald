package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/cli/safeexec"
)

const moduleName = "github.com/anttikivi/reginald"

var tasks = map[string]func(string) error{ //nolint:gochecknoglobals // tasks can as well be global, we don't modify it
	"bin/reginald": func(exe string) error {
		info, err := os.Stat(exe)
		if err == nil && !sourceFilesLaterThan(info.ModTime()) {
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
		// ldflags := os.Getenv("GO_LDFLAGS")
		// ldflags = fmt.Sprintf("-X %s/internal/build.Version=%s %s", moduleName, version(), ldflags)
		// ldflags = fmt.Sprintf("-X %s/internal/build.Date=%s %s", moduleName, date(), ldflags)
		//
		// return run("go", "run", "-ldflags", ldflags, "./cmd/docs", "--man", "--path", "./share/man/man1/")
		return run("go", "run", "./cmd/docs", "--man", "--path", "./share/man/man1/")
	},
}

var self string //nolint:gochecknoglobals // self is shared within this script

func main() {
	args := os.Args[:1]

	for _, arg := range os.Args[1:] {
		if idx := strings.IndexRune(arg, '='); idx >= 0 {
			os.Setenv(arg[:idx], arg[idx+1:])
		} else {
			args = append(args, arg)
		}
	}

	if len(args) < 2 { //nolint:mnd // args contains only the name of this script
		if isWindowsTarget() {
			args = append(args, filepath.Join("bin", "reginald.exe"))
		} else {
			args = append(args, "bin/reginald")
		}
	}

	self = filepath.Base(args[0])
	if self == "build" {
		self = "build.go"
	}

	for _, task := range args[1:] {
		t := tasks[normalizeTask(task)]
		if t == nil {
			fmt.Fprintf(os.Stderr, "Don't know how to build task `%s`.\n", task)
			os.Exit(1)
		}

		err := t(task)
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

func sourceFilesLaterThan(t time.Time) bool { //nolint:varnamelen // t is good enough
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
	// We would use `syscall.ERROR_ACCESS_DENIED` if this script supported build tags.
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
	exe, err := safeexec.LookPath(args[0])
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

	return tn
}

func run(args ...string) error {
	exe, err := safeexec.LookPath(args[0])
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
