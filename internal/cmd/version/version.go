package version

import (
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/anttikivi/go-semver"
	"github.com/anttikivi/reginald/internal/cmd"
	"github.com/anttikivi/reginald/internal/constants"
)

// Name of version command.
const Name = "version"

// New returns a new version command with version v.
func New(v string) (*cmd.Command, error) {
	c := &cmd.Command{
		UsageLine: Name,
		Version:   v,
		Run: func(cmd *cmd.Command, args []string) error {
			fmt.Fprintln(os.Stdout, versionString(cmd.Version))

			return nil
		},
		Setup: nil,
	}

	return c, nil
}

func versionString(v string) string {
	s := "build"

	if semver.IsValid(v) {
		s = "version"
	}

	return strings.ToLower(constants.Name) + " " + s + " " + v + " " + runtime.GOOS + "/" + runtime.GOARCH
}
