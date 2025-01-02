package strutil

import "strings"

// Cap caps lines in string s so that they have the maximum length of l.
// It only breaks lines at spaces.
// Please note that Cap ignores extra spaces.
func Cap(s string, l int) string { //nolint:varnamelen // standard variable names
	var sb strings.Builder

	lines := strings.Split(s, "\n")
	for _, line := range lines {
		words := strings.Fields(line)
		if len(words) == 0 {
			sb.WriteByte('\n')

			continue
		}

		ll := 0

		for _, w := range words {
			wl := len(w)

			if ll > 0 && ll+1+wl > l {
				sb.WriteByte('\n')

				ll = 0
			}

			if ll > 0 {
				sb.WriteByte(' ')

				ll++
			}

			sb.WriteString(w)

			ll += wl
		}

		sb.WriteByte('\n')
	}

	if strings.HasSuffix(s, "\n") {
		return strings.TrimRight(sb.String(), "\n") + "\n"
	}

	return strings.TrimRight(sb.String(), "\n")
}
