// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"os"

	"github.com/anttikivi/reginald/internal/reggie"
)

func main() {
	code := int(reggie.Run())
	os.Exit(code)
}
