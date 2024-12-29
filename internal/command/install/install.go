package install

import "github.com/spf13/cobra"

func NewCommand() *cobra.Command {
	return &cobra.Command{ //nolint:exhaustruct
		Use:   "install",
		Short: "Ask Reginald to install your environment",
	}
}
