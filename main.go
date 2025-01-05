package main

import (
	"os"

	"github.com/anttikivi/reginald/internal/rgl"
)

func main() {
	code := int(rgl.Run())
	os.Exit(code)
}
