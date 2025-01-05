//nolint:lll // This file contains the input for generating documentation.
package command

import (
	"strings"

	"github.com/anttikivi/reginald/internal/constants"
)

func docsAnnotations() map[string]string {
	fullFileName := strings.ToLower(constants.Name)
	fileName := strings.ToLower(constants.Name)

	return map[string]string{
		"docs_long": constants.Name + ` is the workstation valet for managing your workstation configuration and installed tools. It can bootstrap your local workstation, keep your "dotfiles" up to date by managing symlinks to them, and take care of whatever task you want to.

To use ` + constants.Name + `, call one of the commands or read the man page for more information. Simply running **` + constants.CommandName + `** prints the help message.

Please note that ` + constants.Name + ` is still in development, and not all of the promised feature are implemented.`,
		"docs_usage": constants.Name + "[-v | --version] [-h | --help] [--color | --no-color] [-c <path> | --config-file <path>] [-C <path> | --directory <path>] [--log-file <path> | --log-stderr | --log-stdout | --no-logs] [--log-level] [--log-format <\"json\"|\"text\">] [--no-log-rotation] [--plain-logs] <command> [<args>]",
		"docs_short": "the workstation valet",

		"docs_flag_color_name":  "[no-]color",
		"docs_flag_color_usage": `Explicitly enable or disable colors in the command-line output. By default, this is determined automatically.`,

		"docs_flag_configfile_usage": `Overrides the default configuration file lookup and only loads the configuration file from the specified ` + "`path`" + `. If the path is a relative path, it is looked up relative to the current working directory. If it is an absolute path, it is used as it is. User home directory ("~") and environment variables are automatically expanded.

The configuration file **must** always have the file format as the file type. This is true even if you specify a custom configuration file. For example, if the listing for the configuration file lookup specifies "` + fullFileName + `" as a possible configuration file, the file’s name must be "` + fullFileName + `.toml", "` + fullFileName + `.json", or "` + fullFileName + `.yml".

By default, ` + constants.Name + ` looks for the configuration from various locations and uses whichever it finds first in the lookup order. The order is as follows:
""ol""
1. A file named "` + fullFileName + `", "` + fileName + `", ".` + fullFileName + `", or ".` + fileName + `" in the directory specified with the -C or --directory flag.
2. A file named "` + fullFileName + `", "` + fileName + `", ".` + fullFileName + `", or ".` + fileName + `" in the current working directory.
3. A file named "config" at $XDG_CONFIG_HOME/` + fullFileName + `.
4. A file named "` + fullFileName + `" or "` + fileName + `" in $XDG_CONFIG_HOME.
5. A file named "config" at ~/.config/` + fullFileName + `.
6. A file named "` + fullFileName + `" or "` + fileName + `" in ~/.config.
7. A file named "` + fullFileName + `", "` + fileName + `", ".` + fullFileName + `", or ".` + fileName + `" in the user’s home directory.
""endol""`,

		"docs_flag_directory_usage": `Run with the directory at <` + "`path`" + `> as the so-called dotfiles directory. Without additional configuration in for the run steps, ` + constants.Name + ` uses this directory for creating symbolic links for the dotfiles.

The standard pattern is to have the desired configuration in this directory and to let ` + constants.Name + ` create symbolic link to it to a path in the configuration lookup as part of the initial installation. This eliminates the need for the --directory flag for subsequent runs, if the configuration file has the "**directory**" option.`,

		"docs_flag_plainlogs_usage": `Print the logging output of ` + constants.Name + ` without the additional coloring and "pretty-printing" if the output of the logs is set to either stderr or stdout. This flag has no effect if the logs are not printed to either of those or if using colors is disabled (see the --[no-]color flag for more information). If the format of the logs is set to JSON, the logs are printed to the output without colors but setting this flag disables including information on the caller of the log function in the log output.`,
		"docs_flag_logfile_usage":   `Print the logging output of ` + constants.Name + ` to file at the given <` + "`path`" + `>. The format of the logging outputs is determined by the --log-format flag. If no format is specified in the configuration, the default is "json" for logging to a file.`,
		"docs_flag_logstderr_usage": `Print the logging output of ` + constants.Name + ` to stderr. The format of the logging outputs is determined by the --log-format flag. If no format is specified in the configuration, the default is "text" for logging to stderr.`,
		"docs_flag_logstdout_usage": `Print the logging output of ` + constants.Name + ` to stdout. The format of the logging outputs is determined by the --log-format flag. If no format is specified in the configuration, the default is "text" for logging to stdout.`,
		"docs_flag_nologs_usage":    `Disable the logging output of ` + constants.Name + ` altogether. If logging is disabled, all logging calls use a special null handler that totally discards all output.`,

		"docs_flag_logformat_usage":   `Print the logging output of ` + constants.Name + ` in the given <format>. Possible values are "json" and "text". If no value is set in the command-line options or in the configuration, the default is to use "json" when outputting to a file and "text" when outputting to either stderr or stdout.`,
		"docs_flag_logformat_valname": `"json"|"text"`,

		"docs_flag_loglevel_usage": `Only print the logging output of ` + constants.Name + ` with its severity set to at least to <` + "`level`" + `>. The possible levels are "debug", "info", "warn", "error", and "off". The values are case-insensitive. You can also use "warning" as a synonym for "warn" and "err" as a synonym for "error". If the level is set to "off", ` + constants.Name + ` behaves as if logging is completely disabled. See the documentation on --no-logs for explanation of this behavior.`,

		"docs_flag_nologrotation_usage": `Disable the built-in log rotation in ` + constants.Name + ` when the logging output to a file. You should use this flag or disable the log rotation in the configuration if you are using your own log rotation.`,
	}
}
