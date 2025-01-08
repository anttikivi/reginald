package plugin

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/paths"
	rglplugin "github.com/anttikivi/reginald/pkg/plugin"
)

type Discovered struct {
	Name       string
	Executable string
	Plugins    rglplugin.PluginSet
}

func FindTaskPlugins(dir string) (map[string]Discovered, error) {
	original := dir

	dir, err := paths.Abs(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to convert %s into absolute path: %w", original, err)
	}

	files, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to read the directory %s: %w", dir, err)
	}

	for _, f := range files {
		if f.IsDir() {
			fmt.Println(f.Name())

			if err := run("go", "build", "-o", fmt.Sprintf("./bin/%s", f.Name()), fmt.Sprintf("./plugins/%s", f.Name())); err != nil {
				return fmt.Errorf("failed to build %s: %w", f.Name(), err)
			}
		}
	}
}
