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

// manualSectionName is the name of the manual section in the man page header.
const manualSectionName = "Reginald Manual"

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

	return renderMan(f, cmd, &ManHeader{ //nolint:exhaustruct // the fields are filled later
		Section: section,
		Source:  opts.VersionString,
		Manual:  manualSectionName,
	})
}

func renderMan(w io.Writer, cmd *cobra.Command, header *ManHeader) error {
	if err := fillHeader(header, cmd.CommandPath()); err != nil {
		return fmt.Errorf("%w", err)
	}

	b := genMan(cmd, header)
	if _, err := w.Write(b); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func fillHeader(header *ManHeader, name string) error {
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
				return fmt.Errorf("invalid SOURCE_DATE_EPOCH: %w", err)
			}

			now = time.Unix(unixEpoch, 0)
		}

		header.Date = &now
	}

	return nil
}

// genMan generates the man page. Right now, it only implements `roff` syntax, but I might implement `mdoc` in the future.
// The `roff` syntax reference I found: https://jwodder.github.io/kbits/posts/writing-manpages
// The `mdoc` reference I found: https://man.freebsd.org/cgi/man.cgi?mdoc
func genMan(cmd *cobra.Command, header *ManHeader) []byte {
	cmd.InitDefaultHelpCmd()
	cmd.InitDefaultHelpFlag()

	// Something like `rootcmd-subcmd1-subcmd2`.
	dashCommandName := strings.ReplaceAll(cmd.CommandPath(), " ", "-")

	buf := new(bytes.Buffer)

	manPreamble(buf, header, cmd, dashCommandName)

	return buf.Bytes()
}

func manPreamble(buf *bytes.Buffer, header *ManHeader, cmd *cobra.Command, dashedName string) {
	fmt.Fprintf(buf, ".TH %s %s %q %q %q\n", header.Title, header.Section, header.Date.Format("January 2, 2006"), header.Source, header.Manual)
	buf.WriteString(".SH NAME\n")
	fmt.Fprintf(buf, "%s \\- %s\n", dashedName, cmd.Short)
}
