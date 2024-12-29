package version

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/anttikivi/reginald/internal/semver"
	"github.com/spf13/cobra"
)

const CmdName = "version"

func Template(cmd *cobra.Command) string {
	return strings.TrimSuffix(cmd.VersionTemplate(), "\n") + " " + runtime.GOOS + "/" + runtime.GOARCH + "\n"
}

func NewCommand(n string, v semver.Version) *cobra.Command {
	return &cobra.Command{ //nolint:exhaustruct
		Use:   CmdName,
		Short: "Print the version information of " + constants.Name,
		Run: func(_ *cobra.Command, _ []string) {
			fmt.Fprintln(os.Stdout, strings.ToLower(constants.Name)+" version "+v.String()+" "+runtime.GOOS+"/"+runtime.GOARCH)
		},
	}
}
