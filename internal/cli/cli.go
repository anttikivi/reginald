// Package cli defines the command-line interface of Reginald.
package cli

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"github.com/anttikivi/reginald/internal/config"
	"github.com/anttikivi/reginald/internal/flags"
	"github.com/anttikivi/reginald/internal/iostreams"
	"github.com/anttikivi/reginald/internal/logging"
	"github.com/anttikivi/reginald/internal/plugins"
	"github.com/spf13/pflag"
	"golang.org/x/term"
)

// Program-related constants.
const (
	ProgramName = "Reginald" // canonical name for the program
	Name        = "reginald" // name of the command that's run
)

// errMutuallyExclusive is returned when the user sets two mutually exclusive
// flags from the same group at the same time.
var errMutuallyExclusive = errors.New("two mutually exclusive flags set at the same time")

// A CLI is the command-line interface that runs the program. It handles
// subcommands, global command-line flags, and the program execution. The "root
// command" of the CLI is represented by the CLI itself and should not a
// separate [Command] within the CLI.
//
// NOTE: This struct creates some duplications as some of the functionality from
// the commands must be copied to the CLI. I still find the model where we have
// one CLI struct instead of a CLI and a separate root command much simpler to
// handle.
type CLI struct {
	UsageLine string // one-line synopsis of the program

	args                   []string          // command-line arguments after parsing
	cmd                    *Command          // command to run
	cfg                    *config.Config    // parsed config of the run
	commands               []*Command        // list of subcommands
	pluginCommands         []*Command        // commands received from plugins
	allCommands            []*Command        // internal and plugin subcommands combined
	flags                  *flags.FlagSet    // global command-line flags
	mutuallyExclusiveFlags [][]string        // list of flag names that are marked as mutually exclusive
	plugins                []*plugins.Plugin // loaded plugins
	deferredErr            error             // error returned by the plugin shutdown not captured by the return value
}

// New creates a new CLI and returns it. It panics on errors.
func New() *CLI {
	cli := &CLI{
		UsageLine:              Name + " [--version] [-h | --help] <command> [<args>]",
		args:                   []string{},
		cmd:                    nil,
		cfg:                    nil,
		commands:               []*Command{},
		pluginCommands:         []*Command{},
		allCommands:            []*Command{},
		flags:                  flags.NewFlagSet(Name, pflag.ContinueOnError),
		mutuallyExclusiveFlags: [][]string{},
		plugins:                []*plugins.Plugin{},
		deferredErr:            nil,
	}

	cli.flags.Bool("version", false, "print the version information and exit", "")
	cli.flags.BoolP("help", "h", false, "show the help message and exit", "")

	cli.flags.StringP(
		"directory",
		"C",
		config.DefaultDirectory(),
		fmt.Sprintf(
			"run as if %s was started in `<path>` instead of the current working directory",
			ProgramName,
		),
		"",
	)
	cli.flags.StringP(
		"config",
		"c",
		"",
		"use `<path>` as the configuration file instead of resolving it from the standard locations",
		"",
	)

	d, err := config.DefaultPluginsDir()
	if err != nil {
		panic(fmt.Sprintf("failed to get the default plugins directory: %v", err))
	}

	cli.flags.StringP("plugin-dir", "p", d, "search for plugins from `<path>`", "")

	cli.flags.BoolP(
		"verbose",
		"v",
		false,
		"make "+ProgramName+" print more output during the run",
		"",
	)
	cli.flags.BoolP(
		"quiet",
		"q",
		false,
		"make "+ProgramName+" print only error messages during the run",
		"",
	)
	cli.markFlagsMutuallyExclusive("quiet", "verbose")

	isTerminal := term.IsTerminal(int(os.Stdout.Fd()))

	cli.flags.Bool("color", isTerminal, "enable colors in the output", "")
	cli.flags.Bool("no-color", !isTerminal, "disable colors in the output", "")
	cli.markFlagsMutuallyExclusive("color", "no-color")

	if err := cli.flags.MarkHidden("no-color"); err != nil {
		panic(fmt.Sprintf("failed to mark --no-color hidden: %v", err))
	}

	cli.flags.Bool("logging", false, "enable logging", "")
	cli.flags.Bool("no-logging", false, "disable logging", "")
	cli.markFlagsMutuallyExclusive("logging", "no-logging")

	if err := cli.flags.MarkHidden("no-logging"); err != nil {
		panic(fmt.Sprintf("failed to mark --no-logging hidden: %v", err))
	}

	cli.add(NewApply())

	return cli
}

// DeferredErr returns the error from the CLI that was set during cleaning up
// the execution.
func (c *CLI) DeferredErr() error {
	return c.deferredErr
}

// Execute executes the CLI. It parses the command-line options, finds the
// correct command to run, and executes it. An error is returned on user errors.
// The function panics if it is called with invalid program configuration.
func (c *CLI) Execute(ctx context.Context) error {
	if ok, err := c.runFirstPass(ctx); err != nil {
		return fmt.Errorf("%w", err)
	} else if !ok {
		return nil
	}

	// Plugins are started in runFirstPass so defer shutting them down. We want
	// to aim for a clean plugin shutdown in all cases.
	defer func() {
		timeoutCtx, cancel := context.WithTimeout(ctx, plugins.DefaultShutdownTimeout)
		defer cancel()

		if err := plugins.ShutdownAll(timeoutCtx, c.plugins); err != nil {
			c.deferredErr = fmt.Errorf("failed to shut down plugins: %w", err)
		}
	}()

	if err := c.setup(ctx); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := c.run(ctx, c.cmd, c.args); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// add adds the given command to the list of commands of c and marks c as the
// CLI of cmd.
func (c *CLI) add(cmd *Command) {
	cmd.cli = c

	if cmd.mutuallyExclusiveFlags == nil {
		cmd.mutuallyExclusiveFlags = [][]string{}
	}

	cmd.mutuallyExclusiveFlags = append(cmd.mutuallyExclusiveFlags, c.mutuallyExclusiveFlags...)

	c.commands = append(c.commands, cmd)
}

// addPluginCmd adds the given command to the list of plugin commands of c and
// marks c as the CLI of cmd.
func (c *CLI) addPluginCmd(cmd *Command) {
	cmd.cli = c

	if cmd.mutuallyExclusiveFlags == nil {
		cmd.mutuallyExclusiveFlags = [][]string{}
	}

	cmd.mutuallyExclusiveFlags = append(cmd.mutuallyExclusiveFlags, c.mutuallyExclusiveFlags...)

	c.pluginCommands = append(c.pluginCommands, cmd)
}

// runFirstPass does the priority actions of the program. It checks it the
// "--version" or "--help" flags were invoked and loads the plugins from the
// configured location. It should run before entering the rest of the execution
// to have all of the command-line flags and configuration options from the
// plugin available when the final parsing of the configuration is done. The
// function returns true if the execution should not return after this function.
func (c *CLI) runFirstPass(ctx context.Context) (bool, error) {
	args := os.Args
	fs := c.initFirstPassFlags()

	// Ignore errors for now as we want to get all of the flags from plugins
	// first.
	_ = fs.Parse(args)

	help, err := fs.GetBool("help")
	if err != nil {
		return false, fmt.Errorf(
			"failed to get the value for command-line option '--help': %w",
			err,
		)
	}

	if help {
		if err = printHelp(); err != nil {
			return false, fmt.Errorf("failed to print the usage info: %w", err)
		}

		return false, nil
	}

	version, err := fs.GetBool("version")
	if err != nil {
		return false, fmt.Errorf(
			"failed to get the value for command-line option '--version': %w",
			err,
		)
	}

	if version {
		if err = printVersion(); err != nil {
			return false, fmt.Errorf("failed to print the version info: %w", err)
		}

		return false, nil
	}

	// The first-pass config will be replaced by the "real" config later.
	// TODO: Add a faster parsing function for the first-pass config.
	c.cfg, err = c.parseConfig(ctx, fs)
	if err != nil {
		return false, fmt.Errorf("failed to parse the first-pass config: %w", err)
	}

	// Initialize the output streams for user output.
	iostreams.Streams = iostreams.New(c.cfg.Quiet, c.cfg.Verbose, c.cfg.Color)

	if err := logging.Init(c.cfg.Logging); err != nil {
		return false, fmt.Errorf("failed to init the logger: %w", err)
	}

	slog.InfoContext(ctx, "logging initialized")

	if err = c.loadPlugins(ctx); err != nil {
		return false, fmt.Errorf("failed to resolve plugins: %w", err)
	}

	if err = c.addPluginCommands(); err != nil {
		return false, fmt.Errorf("failed to add plugin commands: %w", err)
	}

	return true, nil
}

// initFirstPassFlags creates a temporary flag set for parsing the command-line
// arguments during the first pass before loading the plugins.
func (c *CLI) initFirstPassFlags() *flags.FlagSet {
	fs := flags.NewFlagSet(c.flags.Name(), pflag.ContinueOnError)

	fs.AddFlagSet(c.flags)

	return fs
}

// parseConfig parses the configuration from the configuration files,
// environment variables, and command-line flags. It returns a pointer to the
// configuration and any errors encountered.
func (c *CLI) parseConfig(ctx context.Context, fs *flags.FlagSet) (*config.Config, error) {
	cfg, err := config.Parse(ctx, fs)
	if err != nil {
		return nil, fmt.Errorf("failed to parse the config: %w", err)
	}

	slog.InfoContext(ctx, "config parsed", "config", cfg)

	return cfg, nil
}

// loadPlugins finds and executes all of the plugins in the plugins directory
// found in the configuration in c. It sets plugins in c to a slice of pointers
// to the found and executed plugins.
func (c *CLI) loadPlugins(ctx context.Context) error {
	var pluginFiles []string

	dir := c.cfg.PluginDir

	entries, err := os.ReadDir(dir)
	if err != nil {
		return fmt.Errorf("failed to read plugins directory %s: %w", dir, err)
	}

	for _, entry := range entries {
		path := filepath.Join(dir, entry.Name())

		if entry.IsDir() {
			slog.DebugContext(ctx, "plugin file is a directory", "path", path)

			continue
		}

		if !entry.Type().IsRegular() {
			continue
		}

		info, err := os.Stat(path)
		if err != nil {
			return fmt.Errorf("failed to check the file info for %s: %w", path, err)
		}

		if info.Mode()&0o111 == 0 {
			slog.DebugContext(ctx, "plugin file is not executable", "path", path)

			continue
		}

		if strings.HasPrefix(entry.Name(), Name+"-") {
			pluginFiles = append(pluginFiles, path)
		}
	}

	slog.DebugContext(ctx, "performed the plugin lookup", "plugins", pluginFiles)

	if c.plugins, err = plugins.Load(ctx, pluginFiles); err != nil {
		return fmt.Errorf("failed to load the plugins: %w", err)
	}

	return nil
}

// addPluginCommands adds the commands from the loaded plugins to c.
func (c *CLI) addPluginCommands() error {
	for _, p := range c.plugins {
		for _, info := range p.Commands {
			cmd := &Command{ //nolint:exhaustruct
				Name:      info.Name,
				UsageLine: info.UsageLine,
				Setup:     nil,
				Run: func(ctx context.Context, cmd *Command, args []string) error {
					if err := p.RunCmd(ctx, cmd.Name, args); err != nil {
						return fmt.Errorf(
							"failed to run command %q from plugin %q: %w",
							cmd.Name,
							p.Name,
							err,
						)
					}

					return nil
				},
			}

			for _, f := range info.Flags {
				if err := cmd.Flags().AddPluginFlag(f); err != nil {
					return fmt.Errorf(
						"failed to add flag from plugin %q and command %q: %w",
						p.Name,
						info.Name,
						err,
					)
				}
			}

			c.addPluginCmd(cmd)
		}
	}

	c.allCommands = append(c.allCommands, c.commands...)
	c.allCommands = append(c.allCommands, c.pluginCommands...)

	return nil
}

// setup runs the setup phase of the program.
func (c *CLI) setup(ctx context.Context) error {
	var err error

	args := os.Args

	// TODO: Should we make sure that CommandLine is not used and should we do
	// it this way?
	pflag.CommandLine.VisitAll(func(f *pflag.Flag) {
		panic(fmt.Sprintf("flag %q is set in the CommandLine flag set", f.Name))
	})
	// Matches merging flags for commands.
	// c.flags.AddFlagSet(pflag.CommandLine)
	slog.DebugContext(ctx, "parsing command-line arguments", "args", args)

	c.cmd, args = c.findSubcommand(ctx, args)

	var flagSet *flags.FlagSet

	if c.cmd == nil {
		flagSet = c.flags
	} else {
		c.cmd.mergeFlags()
		flagSet = c.cmd.Flags()
	}

	if err := flagSet.Parse(args); err != nil {
		return fmt.Errorf("failed to parse command-line arguments: %w", err)
	}

	c.args = flagSet.Args()

	if err := c.checkMutuallyExclusiveFlags(c.cmd); err != nil {
		return fmt.Errorf("%w", err)
	}

	c.cfg, err = c.parseConfig(ctx, flagSet)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// checkMutuallyExclusiveFlags checks if two flags marked as mutually exclusive
// are set at the same time by the user. The function returns an error if two
// mutually exclusive flags are set.
func (c *CLI) checkMutuallyExclusiveFlags(cmd *Command) error {
	var (
		fs                     *flags.FlagSet
		mutuallyExclusiveFlags [][]string
	)

	if cmd == nil {
		fs = c.flags
		mutuallyExclusiveFlags = c.mutuallyExclusiveFlags
	} else {
		fs = cmd.Flags()
		mutuallyExclusiveFlags = cmd.mutuallyExclusiveFlags
	}

	if !fs.Parsed() {
		panic("checkMutuallyExclusiveFlags called before the flags were parsed")
	}

	for _, a := range mutuallyExclusiveFlags {
		var set string

		for _, s := range a {
			f := fs.Lookup(s)
			if f == nil {
				panic("nil flag in the set of mutually exclusive flags: " + s)
			}

			if f.Changed {
				if set != "" {
					return fmt.Errorf(
						"%w: --%s and --%s (or their shorthands)",
						errMutuallyExclusive,
						set,
						s,
					)
				}

				set = s
			}
		}
	}

	return nil
}

// findSubcommand finds the subcommand to run from the command tree starting at
// c. It returns the final command and the command-line arguments, and
// command-line flags. If no subcommand is found (i.e. the root command should
// be run), this function returns nil as the first return value.
func (c *CLI) findSubcommand(ctx context.Context, args []string) (*Command, []string) {
	if len(args) <= 1 {
		return nil, args
	}

	var cmd *Command

	fs := c.flags
	flags := []string{}

	for len(args) >= 1 {
		if len(args) > 1 {
			args, flags = collectFlags(fs, args[1:], flags)
		}

		if len(args) >= 1 {
			var next *Command

			if cmd == nil {
				next = c.lookup(args[0])
			} else {
				next = cmd.Lookup(args[0])
			}

			if next == nil {
				break
			}

			cmd = next
		}
	}

	if len(args) > 0 && cmd != nil && args[0] == cmd.Name {
		args = args[1:]
	}

	if cmd == nil {
		slog.DebugContext(ctx, "no command found", "cmd", os.Args[0], "args", args, "flags", flags)
	} else {
		slog.DebugContext(ctx, "found subcommand", "cmd", cmd.Name, "args", args, "flags", flags)
	}

	args = append(args, flags...)

	return cmd, args
}

// lookup returns the command from this CLI for the given name, if any.
// Otherwise it returns nil.
func (c *CLI) lookup(name string) *Command {
	if c.allCommands == nil {
		panic("called CLI function lookup before initializing all of the list of all commands")
	}

	for _, cmd := range c.allCommands {
		// TODO: Check for aliases.
		if cmd.Name == name {
			return cmd
		}
	}

	return nil
}

// markFlagsMutuallyExclusive marks two or more flags as mutually exclusive so
// that the program returns an error if the user tries to set them at the same
// time.
func (c *CLI) markFlagsMutuallyExclusive(a ...string) {
	if len(a) < 2 { //nolint:mnd
		panic("only one flag cannot be marked as mutually exclusive")
	}

	for _, s := range a {
		if f := c.flags.Lookup(s); f == nil {
			panic(fmt.Sprintf("failed to find flag %q while marking it as mutually exclusive", s))
		}
	}

	if c.mutuallyExclusiveFlags == nil {
		panic(
			"mutually exclusive flags of the CLI should have been initialized when the struct was created",
		)
	}

	c.mutuallyExclusiveFlags = append(c.mutuallyExclusiveFlags, a)
}

// run runs the setup and execution of the resolved command.
func (c *CLI) run(ctx context.Context, cmd *Command, args []string) error {
	if cmd == nil {
		return nil
	}

	if err := setupCommands(ctx, cmd, cmd, args); err != nil {
		return fmt.Errorf("%w", err)
	}

	if err := cmd.Run(ctx, cmd, args); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// setupCommands runs [Command.Setup] for all of the commands, starting from the
// root command. It exits on the first error it encounters.
func setupCommands(ctx context.Context, c, subcmd *Command, args []string) error {
	if c.HasParent() {
		if err := setupCommands(ctx, c.parent, subcmd, args); err != nil {
			return fmt.Errorf("%w", err)
		}
	}

	if c.Setup != nil {
		if err := c.Setup(ctx, c, subcmd, args); err != nil {
			return fmt.Errorf("%w", err)
		}
	}

	return nil
}
