// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package git

import (
	"fmt"

	"github.com/anttikivi/reginald/internal/exit"
	"github.com/anttikivi/reginald/internal/runner"
)

func Clone(r *runner.Runner, repo, dir string) error {
	git, err := Lookup(r)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	if err = r.Runf([]string{git, "clone", repo, dir}, "Cloning from %s...", repo); err != nil {
		if i, ok := runner.IsExit(err); ok {
			return exit.New(exit.Code(i), fmt.Errorf("%w", err))
		}

		return exit.New(exit.ExecFailure, fmt.Errorf("%w", err))
	}

	return nil
}

func Lookup(r *runner.Runner) (string, error) {
	git, err := r.LookPath("git")
	if err != nil {
		return "", fmt.Errorf("cound not find an executable for %q: %w", "git", err)
	}

	return git, nil
}
