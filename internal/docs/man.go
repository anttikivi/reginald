package docs

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/anttikivi/reginald/internal/constants"
	"github.com/spf13/cobra"
)

type ManTreeOptions struct {
	Path             string
	CommandSeparator string
	VersionString    string
}

type ManHeader struct {
	Title   string
	Section string
	Date    *time.Time
	Source  string
	Manual  string
}

const (
	// manLineLength is the maximum line length for formatting the man page.
	// It is used to cap the line length of synopsis.
	manLineLength = 80

	// manualSectionName is the name of the manual section in the man page header.
	manualSectionName = "Reginald Manual"
)

// const manualSectionName = "General Commands Manual" // section 1: general commands

func GenerateManTree(cmd *cobra.Command, dir string) error {
	v := cmd.Version

	return genManTreeFromOpts(cmd, ManTreeOptions{
		Path:             dir,
		CommandSeparator: "-",
		VersionString:    constants.Name + " " + v,
	})
}

func genManTreeFromOpts(cmd *cobra.Command, opts ManTreeOptions) error {
	for _, c := range cmd.Commands() {
		if !c.IsAvailableCommand() || c.IsAdditionalHelpTopicCommand() {
			continue
		}

		if err := genManTreeFromOpts(c, opts); err != nil {
			return err
		}
	}

	section := "1"
	separator := "_"

	if opts.CommandSeparator != "" {
		separator = opts.CommandSeparator
	}

	basename := strings.ReplaceAll(cmd.CommandPath(), " ", separator)
	filename := filepath.Join(opts.Path, basename+"."+section)

	f, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer f.Close()

	header := &ManHeader{ //nolint:exhaustruct // the fields are filled in below
		Section: section,
		Source:  opts.VersionString,
		Manual:  manualSectionName,
	}

	header, err = fillHeader(header, cmd.CommandPath())
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return renderMan(f, cmd, header)
}

func renderMan(w io.Writer, cmd *cobra.Command, header *ManHeader) error {
	b := genMan(cmd, header)
	if _, err := w.Write(b); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func fillHeader(header *ManHeader, name string) (*ManHeader, error) {
	if header.Title == "" {
		header.Title = strings.ToUpper(strings.ReplaceAll(name, " ", "\\-"))
	}

	if header.Section == "" {
		header.Section = "1"
	}

	if header.Date == nil {
		now := time.Now()

		if epoch := os.Getenv("SOURCE_DATE_EPOCH"); epoch != "" {
			unixEpoch, err := strconv.ParseInt(epoch, 10, 64)
			if err != nil {
				return nil, fmt.Errorf("invalid SOURCE_DATE_EPOCH: %w", err)
			}

			now = time.Unix(unixEpoch, 0)
		}

		header.Date = &now
	}

	return header, nil
}

// genMan generates the man page.
// Right now, it only implements `roff` syntax, but I might implement `mdoc` in
// the future.
func genMan(cmd *cobra.Command, header *ManHeader) []byte {
	cmd.InitDefaultHelpCmd()
	cmd.InitDefaultHelpFlag()

	// Something like `rootcmd-subcmd1-subcmd2`.
	dashCommandName := strings.ReplaceAll(cmd.CommandPath(), " ", "-")

	buf := new(bytes.Buffer)

	printPreamble(buf, header, cmd, dashCommandName)
	printOptions(buf, cmd)

	return buf.Bytes()
}

func printPreamble(buf *bytes.Buffer, header *ManHeader, cmd *cobra.Command, dashedName string) {
	fmt.Fprintf(
		buf,
		".TH %q %q %q %q %q\n",
		header.Title,
		header.Section,
		header.Date.Format("January 2, 2006"),
		strings.ReplaceAll(header.Source, ".", "\\&."),
		header.Manual,
	)
	buf.WriteString(".SH NAME\n")

	short := cmd.Short
	if cmd.Annotations != nil {
		if s, ok := cmd.Annotations["docs_short"]; ok {
			short = s
		}
	}

	fmt.Fprintf(buf, "%s \\- %s\n", dashedName, short)
	buf.WriteString(".SH SYNOPSIS\n.sp\n.nf\n")
	buf.WriteString(manSynopsis(cmd))
	buf.WriteString("\n.fi\n.sp\n")

	description := ""

	if cmd.Long != "" && cmd.Long != cmd.Short {
		description = cmd.Long
	}

	if cmd.Annotations != nil {
		if s, ok := cmd.Annotations["docs_long"]; ok {
			description = s
		}

		if s, ok := cmd.Annotations["docs_description"]; ok {
			description = s
		}
	}

	if description != "" {
		buf.WriteString(".SH DESCRIPTION\n.sp\n")

		// It's a convention to include each sentence on its own line.
		description = strings.ReplaceAll(description, ". ", ".\n")
		description = strings.ReplaceAll(description, "\n\n", "\n.sp\n")
		description = strings.ReplaceAll(description, "`", "\\(ga")

		buf.WriteString(description)
		buf.WriteByte('\n')
	}
}

func printOptions(buf *bytes.Buffer, cmd *cobra.Command) {
	flags := cmd.NonInheritedFlags()
	if flags.HasAvailableFlags() {
		buf.WriteString(".SH OPTIONS\n.PP\n")
		printFlags(buf, flags, cmd.Annotations)
	}
}

func manSynopsis(cmd *cobra.Command) string {
	name := cmd.Name()

	for parent := cmd; parent.HasParent(); {
		parent = parent.Parent()
		name = parent.Name() + " " + name
	}

	var sb strings.Builder

	sb.WriteString(fmt.Sprintf("\\fI%s\\fR", name))

	str := cmd.UseLine()
	if cmd.Annotations != nil {
		if s, ok := cmd.Annotations["docs_usage"]; ok {
			str = s
		}
	}

	str = strings.TrimPrefix(str, name)
	str = strings.TrimPrefix(str, " ")
	str = strings.TrimSuffix(str, " [flags]")

	parts := make([]string, 0)

	for i := 0; i < len(str); i++ {
		c := str[i]
		if i == 0 && c == '[' {
			a := str[i : strings.IndexRune(str, ']')+1]
			parts = append(parts, strings.ReplaceAll(a, "-", "\\-"))

			continue
		}

		if i == 0 && c == '<' {
			a := str[i : strings.IndexRune(str, '>')+1]
			parts = append(parts, strings.ReplaceAll(a, "-", "\\-"))

			continue
		}

		if i == 0 {
			continue
		}

		if c == ' ' {
			var a string

			prev := str[i-1]
			next := str[i+1]
			sub := str[i+1:]

			switch {
			case (prev == ']' && next == '[') || (prev == '>' && next == '['):
				a = sub[:strings.IndexRune(sub, ']')+1]
			case (prev == '>' && next == '<') || (prev == ']' && next == '<'):
				a = sub[:strings.IndexRune(sub, '>')+1]
			default:
				continue
			}

			parts = append(parts, strings.ReplaceAll(a, "-", "\\-"))
			i += len(a)
		}
	}

	ll := sb.Len()
	p := strings.Repeat(" ", len(name)+1)

	for _, s := range parts {
		ll += len(s) + 1
		if ll > manLineLength {
			sb.WriteRune('\n')
			sb.WriteString(p)
			sb.WriteString(s)

			ll = len(p) + len(s)
		} else {
			sb.WriteRune(' ')
			sb.WriteString(s)
		}
	}

	return sb.String()
}
