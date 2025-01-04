//nolint:lll // This file contains the input for generating documentation.
package bootstrap

func docsAnnotations() map[string]string {
	return map[string]string{
		"docs_long": `Bootstrap clones the specified dotfiles directory and runs the initial installation.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.`,
	}
}
