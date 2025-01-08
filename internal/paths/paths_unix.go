// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

//go:build !windows

package paths

import "os"

// ExpandEnv replaces ${var} or $var in the string according to the values of
// the current environment variables. References to undefined variables are
// replaced by the empty string.
func ExpandEnv(path string) string {
	return os.ExpandEnv(path)
}
