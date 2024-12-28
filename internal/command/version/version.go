package version

import (
	"fmt"
	"os"
	"runtime"

	"github.com/anttikivi/reginald/internal/semver"
	"github.com/spf13/cobra"
)

func NewVersionCommand(n string, v semver.Version) *cobra.Command {
	return &cobra.Command{ //nolint:exhaustruct
		Use:   "version",
		Short: "Print the version information of Reginald",
		Run:   runVersion(n, v),
	}
}

func runVersion(n string, v semver.Version) func(cmd *cobra.Command, args []string) {
	return func(_ *cobra.Command, _ []string) {
		fmt.Fprintln(os.Stdout, n+" version "+v.String()+" "+runtime.GOOS+"/"+runtime.GOARCH)
	}
}
