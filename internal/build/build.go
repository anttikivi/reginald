// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package build

import "runtime/debug"

// Version is the version data received from the build.
// It is dynamically set by the toolchain or overridden by the Makefile.
var Version = "DEV" //nolint:gochecknoglobals // set at build time

// Date is the build time.
// It is dynamically set at build time in the Makefile.
// Format for the date is "YYYY-MM-DD".
var Date = "" //nolint:gochecknoglobals // set at build time

func init() { //nolint:gochecknoinits // Handles values set at build time, magic is justified.
	if Version == "DEV" {
		if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "(devel)" {
			Version = info.Main.Version
		}
	}
}
