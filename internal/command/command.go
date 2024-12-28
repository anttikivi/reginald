package command

import (
	"errors"
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/command/version"
	"github.com/anttikivi/reginald/internal/semver"
	"github.com/fatih/color"
	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

const (
	Name        = "Reginald"
	CommandName = "reginald"
	ExitError   = 1
)

func NewReginaldCommand(ver semver.Version) (*cobra.Command, error) {
	cmd := &cobra.Command{ //nolint:exhaustruct
		Use:     CommandName + " <command> [flags]",
		Short:   Name + " is the workstation valet",
		Long:    `Reginald is the workstation valet for managing your workstation configuration and installed tools.`,
		Version: ver.String(),
		Run:     runHelp,
	}

	cmd.SetVersionTemplate(version.Template(cmd))

	cmd.PersistentFlags().Bool("color", false, "explicitly enable colors in the command-line output")
	cmd.PersistentFlags().Bool("no-color", false, "disable colors in the command-line output")
	cmd.MarkFlagsMutuallyExclusive("color", "no-color")

	err := cmd.PersistentFlags().MarkHidden("no-color")
	if err != nil {
		return nil, fmt.Errorf("failed to mark the no-color flag as hidden: %w", err)
	}

	err = viper.BindPFlag("color", cmd.PersistentFlags().Lookup("color"))
	if err != nil {
		return nil, fmt.Errorf("failed to bind the flag \"color\" to config: %w", err)
	}

	cmd.AddCommand(version.NewVersionCommand(CommandName, ver))

	cobra.OnInitialize(
		func() {
			setDefaults()

			noColor, err := cmd.Flags().GetBool("no-color")
			if err != nil {
				fmt.Fprintf(os.Stderr, "failed to get the value for the \"no-color\" flag: %v", err)
				os.Exit(ExitError)
			}

			if noColor {
				viper.Set("color", false)
			}

			viper.AddConfigPath(".")
			viper.SetConfigName("reginald")

			viper.AutomaticEnv()

			if !viper.GetBool("color") {
				color.NoColor = true
			}

			if err := viper.ReadInConfig(); err != nil {
				var notFoundError viper.ConfigFileNotFoundError
				if errors.As(err, &notFoundError) {
					fmt.Fprintln(os.Stderr, color.YellowString("configuration file not found"))
				} else {
					fmt.Fprintf(os.Stderr, "could not read the configuration file: %v\n", err)
					os.Exit(ExitError)
				}
			}
		})

	return cmd, nil
}

func setDefaults() {
	viper.SetDefault("color", !color.NoColor)
}

func runHelp(cmd *cobra.Command, _ []string) {
	if err := cmd.Help(); err != nil {
		fmt.Fprintln(os.Stderr, "Failed to run the help command")
		os.Exit(ExitError)
	}
}
