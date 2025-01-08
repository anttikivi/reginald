// Copyright (c) 2025 Antti Kivi
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"os"

	"github.com/anttikivi/reginald/internal/rgl"
	rglplugin "github.com/anttikivi/reginald/pkg/plugin"
)

func main() {
	fmt.Println(rglplugin.PluginTypeCommand)
	fmt.Println(rglplugin.PluginTypeTask)

	code := int(rgl.Run())
	os.Exit(code)
}
