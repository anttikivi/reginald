// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package apply

import (
	"fmt"
	"log/slog"

	"github.com/anttikivi/reginald/pkg/task"
)

type link struct{}

func (l *link) Check(_ task.Settings) error {
	return nil
}

func (l *link) CheckDefaults(settings task.Settings) error {
	for k, v := range settings {
		switch k {
		case "create", "force":
			if _, ok := v.(bool); !ok {
				slog.Info("value in the defaults for link has invalid type", "key", k, "value", v)

				return fmt.Errorf("%w", task.NewInvalidType(l, k, v, "boolean"))
			}
		default:
			slog.Info("invalid key in the defaults for link", "key", k, "value", v)

			return fmt.Errorf("%w", task.NewInvalidKey(l, k))
		}
	}

	return nil
}

func (l *link) Run(_ *task.Config) error {
	return nil
}

func (l *link) Type() string {
	return "link"
}
