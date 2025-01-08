// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"os"

	"github.com/anttikivi/reginald/internal/rgl"
)

var version = "DEV"

func main() {
	code := int(rgl.RunAs(version))
	os.Exit(code)
}
