package docs

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/spf13/pflag"
)

// printFlags prints the command line flags from the given flag set to the
// buffer. It also takes the annotations of the command as parameter and allows
// specifying special values for the flag output using them. The following
// annotations are currently supported:
//   - "flags:flagname:default": Give a custom explanation for a flags default
//     value or behavior. Otherwise, if the flags has a default value, it is
//     printed as, "The default value for --flag is defaultvalue".
//   - "flags:flagname:valname": Give a custom name for the placeholder value
//     printed for the flag. Otherwise the output uses `pflag`'s default value
//     naming.
func printFlags(buf *bytes.Buffer, flags *pflag.FlagSet, annotations map[string]string) {
	var sb strings.Builder

	flags.VisitAll(func(flag *pflag.Flag) {
		if flag.Deprecated != "" || flag.Hidden {
			return
		}

		sb.WriteString(".TP\n")

		valname, usage := flagUsage(flag, annotations)

		sb.WriteString(flagSynopsis(flag, valname, annotations))

		usage = format(usage, flags)

		sb.WriteString(usage)
		sb.WriteByte('\n')
		buf.WriteString(sb.String())
		sb.Reset()
	})
}

func flagKey(flag *pflag.Flag) string {
	return strings.ReplaceAll(flag.Name, "-", "")
}

func flagUsage(flag *pflag.Flag, annotations map[string]string) (string, string) {
	key := flagKey(flag)
	valname, usage := pflag.UnquoteUsage(flag)
	hasCustomUsage := false

	if annotations != nil {
		if s, ok := annotations[fmt.Sprintf("docs_flag_%s_usage", key)]; ok {
			valname, usage = unquoteUsage(flag, s)
			hasCustomUsage = true
		}
	}

	if !hasCustomUsage && flag.DefValue != "" && flag.DefValue != "false" {
		s := fmt.Sprintf("The default value for \\fB\\-\\-%s\\fR is %q.", flag.Name, flag.DefValue)
		usage = fmt.Sprintf("%s\n\n%s", usage, s)
	}

	if annotations != nil {
		if v, ok := annotations[fmt.Sprintf("docs_flag_%s_valname", key)]; ok {
			valname = v
		}
	}

	return valname, usage
}

func customFlag(flag *pflag.Flag, annotations map[string]string) string {
	name := flag.Name
	key := flagKey(flag)

	if annotations != nil {
		if s, ok := annotations[fmt.Sprintf("docs_flag_%s_name", key)]; ok {
			name = s
		}
	}

	return name
}

func flagSynopsis(flag *pflag.Flag, valname string, annotations map[string]string) string {
	var sb strings.Builder

	customFlag := customFlag(flag, annotations)

	if flag.Shorthand != "" && flag.ShorthandDeprecated == "" {
		sb.WriteString(fmt.Sprintf("\\fB\\-%s\\fR", flag.Shorthand))

		if valname != "" {
			sb.WriteString(fmt.Sprintf(" <%s>, ", strings.ReplaceAll(valname, "-", "\\-")))
		} else {
			sb.WriteString(", ")
		}
	}

	sb.WriteString(fmt.Sprintf("\\fB\\-\\-%s\\fR", strings.ReplaceAll(customFlag, "-", "\\-")))

	if valname != "" {
		sb.WriteString(fmt.Sprintf(" <%s>", strings.ReplaceAll(valname, "-", "\\-")))
	}

	sb.WriteByte('\n')

	return sb.String()
}

// unquoteUsage extracts a back-quoted name from the given usage string and
// returns it and the un-quoted usage. The given string should a custom usage
// string for the given flag. Given "a `name` to show" it returns ("name", "a
// name to show"). If there are no back quotes, the name is an educated guess of
// the type of the flag's value, or the empty string if the flag is boolean.
//
// This function is from `spf13/pflag`, licensed under the BSD-3-Clause license.
// Please see the `NOTICE` file for more information.
func unquoteUsage(flag *pflag.Flag, s string) (string, string) {
	var name string

	// Look for a back-quoted name, but avoid the strings package.
	usage := s
	for i := 0; i < len(usage); i++ {
		if usage[i] == '`' {
			for j := i + 1; j < len(usage); j++ {
				if usage[j] == '`' {
					name = usage[i+1 : j]
					usage = usage[:i] + name + usage[j+1:]

					return name, usage
				}
			}

			break // Only one back quote; use type name.
		}
	}

	name = flag.Value.Type()
	switch name {
	case "bool":
		name = ""
	case "float64":
		name = "float"
	case "int64":
		name = "int"
	case "uint64":
		name = "uint"
	case "stringSlice":
		name = "strings"
	case "intSlice":
		name = "ints"
	case "uintSlice":
		name = "uints"
	case "boolSlice":
		name = "bools"
	}

	return name, usage
}
