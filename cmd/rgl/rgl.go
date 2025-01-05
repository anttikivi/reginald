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
