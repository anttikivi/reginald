//go:build windows

package paths_test

import (
	"testing"

	"github.com/anttikivi/reginald/internal/paths"
)

func TestExpandEnv(t *testing.T) {
	tests := []struct {
		path string
		env  map[string]string
		want string
	}{
		{
			"some/path/%WITHVAR%/here",
			map[string]string{"WITHVAR": "var"},
			"some/path/var/here",
		},
		{
			"some/path/%WITHVAR%/here",
			map[string]string{"NOTWITHVAR": "var"},
			"some/path//here",
		},
		{
			"C:\\%VAR%\\some/path/%WITHVAR%/here",
			map[string]string{"VAR": "a-value", "WITHVAR": "var"},
			"C:\\a-value\\some/path/var/here",
		},
		{
			"%some/path/%WITHVAR%/here",
			map[string]string{"some/path/%WITHVAR%/here": "not this!", "WITHVAR": "var"},
			"%some/path/var/here",
		},
		{
			"some/path/%%/here",
			map[string]string{"some/path/%WITHVAR%/here": "not this!", "WITHVAR": "var"},
			"some/path/%/here",
		},
		{
			"%some%/path/var/here",
			map[string]string{"some": "var"},
			"var/path/var/here",
		},
		{
			"%some%/path/var/here",
			map[string]string{},
			"/path/var/here",
		},
		{
			"some/path/var/here",
			map[string]string{},
			"some/path/var/here",
		},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			for k, v := range tt.env {
				t.Setenv(k, v)
			}

			got := paths.ExpandEnv(tt.path)

			if got != tt.want {
				t.Errorf("ExpandEnv(%q) = %v, want %q", tt.path, got, tt.want)
			}
		})
	}
}
