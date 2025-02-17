package main

import (
	"os"

	"github.com/anttikivi/reginald/internal/reggie"
)

var version = "DEV"

func main() {
	code := int(reggie.RunAs(version))
	os.Exit(code)
}
