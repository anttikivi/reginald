// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package apply

import (
	"fmt"
	"log/slog"

	"github.com/anttikivi/reginald/pkg/task"
)

type clean struct{}

func (t *clean) Check(_ task.Settings) error {
	return nil
}

func (t *clean) CheckDefaults(settings task.Settings) error {
	for k, v := range settings {
		switch k {
		case "force":
			if _, ok := v.(bool); !ok {
				slog.Info("value in the defaults for clean has invalid type", "key", k, "value", v)

				return fmt.Errorf("%w", task.NewInvalidType(t, k, v, "boolean"))
			}
		default:
			slog.Info("invalid key in the defaults for clean", "key", k, "value", v)

			return fmt.Errorf("%w", task.NewInvalidKey(t, k))
		}
	}

	return nil
}

func (t *clean) Run(_ *task.Config) error {
	return nil
}

func (t *clean) Type() string {
	return "clean"
}
