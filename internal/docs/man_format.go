package docs

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/spf13/pflag"
)

func format(s string, flags *pflag.FlagSet) string {
	// Format my custom list format.
	re := regexp.MustCompile(`(?s)""ol"".*?""endol""`)
	numRe := regexp.MustCompile(`(?m)^\d+\.\s`)

	s = re.ReplaceAllStringFunc(s, func(s string) string {
		s = strings.ReplaceAll(s, "\"\"ol\"\"", ".RS 8")
		s = numRe.ReplaceAllStringFunc(s, func(str string) string {
			return fmt.Sprintf(".IP \"%s.\" 4\n", strings.TrimSuffix(str, ". "))
		})
		s = strings.ReplaceAll(s, "\"\"endol\"\"", ".RE")

		return s
	})

	boldRe := regexp.MustCompile(`\*\*.*?\*\*`)

	s = boldRe.ReplaceAllStringFunc(s, func(s string) string {
		s = strings.Replace(s, "**", "\\fB", 1)
		s = strings.Replace(s, "**", "\\fR", 1)

		return s
	})

	s = strings.ReplaceAll(s, ". ", ".\n")
	s = strings.ReplaceAll(s, "\n\n", "\n.sp\n")
	s = strings.ReplaceAll(s, "’", "\\(cq")
	s = strings.ReplaceAll(s, "`", "\\(ga")
	s = strings.ReplaceAll(s, "~", "\\(ti")

	if flags != nil {
		for _, f := range strings.Fields(s) {
			if strings.HasPrefix(f, "--") {
				if f := flags.Lookup(strings.TrimPrefix(f, "--")); f != nil {
					s = strings.ReplaceAll(
						s,
						fmt.Sprintf(" --%s ", f.Name),
						fmt.Sprintf(" \\fB\\-\\-%s\\fR ", strings.ReplaceAll(f.Name, "-", "\\-")),
					)
				}
			} else if len(f) == 2 && strings.HasPrefix(f, "-") {
				if f := flags.ShorthandLookup(strings.TrimPrefix(f, "-")); f != nil {
					s = strings.ReplaceAll(
						s,
						fmt.Sprintf(" -%s ", f.Shorthand),
						fmt.Sprintf(" \\fB\\-%s\\fR ", f.Shorthand),
					)
				}
			}
		}
	}

	return s
}
