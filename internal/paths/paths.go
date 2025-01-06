package paths

import (
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

// Abs returns an absolute representation of path. If the path is not absolute
// it will be joined with the current working directory to turn it into an
// absolute path. Abs calls Clean on the result. Abs also resolves user home
// directories and environment variables.
func Abs(path string) (string, error) {
	path = ExpandEnv(path)

	var err error

	path, err = ExpandUser(path)
	if err != nil {
		return "", fmt.Errorf("failed to expand user home directory: %w", err)
	}

	path, err = filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}

	return path, nil
}

// ExpandUser tries to replace "~" or "~username" in the string to match the
// correspending user's home directory. If the wanted user does not exist, this
// function returns an error.
func ExpandUser(path string) (string, error) {
	if path == "~" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("failed to get the user home dir: %w", err)
		}

		return home, nil
	}

	if strings.HasPrefix(path, "~") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("failed to get the user home dir: %w", err)
		}

		// Using the current user's home directory.
		if path[1] == '/' || path[1] == os.PathSeparator {
			return filepath.Join(home, path[1:]), nil
		}

		path, err = expandOtherUser(path)
		if err != nil {
			return "", fmt.Errorf("%w", err)
		}
	}

	return path, nil
}

func expandOtherUser(path string) (string, error) {
	// Otherwise we try to look up the wanted user.
	var (
		i        int
		username string
	)

	if i = strings.IndexByte(path, os.PathSeparator); i != -1 {
		username = path[1:i]
	} else if i = strings.IndexByte(path, '/'); i != -1 {
		username = path[1:i]
	} else {
		username = path[1:]
	}

	u, err := user.Lookup(username)
	if err != nil {
		return "", fmt.Errorf("failed to look up user %q: %w", username, err)
	}

	if i == -1 {
		return u.HomeDir, nil
	}

	return filepath.Join(u.HomeDir, path[i:]), nil
}
