package bootstrap

import (
	"fmt"
	"log/slog"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/strutil"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

// helpDescription is the description printed when the command is run with the
// `--help` flag.
//
//nolint:gochecknoglobals,lll // It is easier to have this here instead of inlining.
var helpDescription = `Bootstrap clones the specified dotfiles directory and runs the initial installation.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.
`

func NewCommand() *cobra.Command {
	return &cobra.Command{ //nolint:exhaustruct // we want to use the default values
		Use:         "bootstrap",
		Aliases:     []string{"clone", "init", "initialise", "initialize"},
		Short:       "Ask " + constants.Name + " to bootstrap your environment",
		Long:        strutil.Cap(helpDescription, constants.HelpLineLen),
		Args:        cobra.NoArgs,
		Annotations: docsAnnotations(),
		RunE:        run,
	}
}

func run(cmd *cobra.Command, _ []string) error {
	slog.Info("Running the bootstrap command")

	cfg, ok := cmd.Context().Value(constants.ConfigContextKey).(*viper.Viper)
	if !ok || cfg == nil {
		return fmt.Errorf("%w", constants.ErrNoConfig)
	}

	slog.Debug("Retrieved the config", slog.Any("cfg", cfg.AllSettings()))

	return nil
}
