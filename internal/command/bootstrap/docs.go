// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

//nolint:lll // This file contains the input for generating documentation.
package bootstrap

func docsAnnotations() map[string]string {
	return map[string]string{
		"docs_long": `Bootstrap clones the specified dotfiles directory and runs the initial installation. It accepts two positional arguments, the remote repository and the directory where it should be cloned to, in that order. You can also specify those using the other configuration sources, please consult the documentation on configuration. Giving the remote repository and the directory using the positional arguments always takes precedence.

Bootstrapping should only be run in an environment that is not set up. The command will fail if the dotfiles directory already exists.

After bootstrapping, please use the ` + "`install`" + ` command for subsequent runs.`,
	}
}
