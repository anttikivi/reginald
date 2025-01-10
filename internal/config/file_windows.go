//go:build windows

package config

import (
	"fmt"
	"os"
	"path/filepath"
)

const defaultConfigSubdir = "reginald"

func defaultConfigDir() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("failed to resolve user's config directory: %w", err)
	}

	return filepath.Join(dir, defaultConfigSubdir), nil
}
