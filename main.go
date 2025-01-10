// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"os"

	"github.com/anttikivi/reginald/internal/rgl"
)

func main() {
	code := int(rgl.Run())
	os.Exit(code)
}
