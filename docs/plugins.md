# Reginald Plugins

Reginald can be extended with plugins that can define arbitrary commands and
tasks. In the current plugin system, each plugin is an executable that is
started by Reginald and that communicates with Reginald with JSON-RPC 2.0. Each
plugin must also include a manifest file that contains the information that is
required for starting up the plugin executable. This document describes the
structure of the plugins and the communication protocol that the plugins and
Reginald use.

## Plugin lookup and structure

Reginald looks for plugins in different directories. By default, plugins are
searched for from the following locations:

- All platforms: `$XDG_DATA_HOME/reginald/plugins`.
- Darwin (macOS): `~/Library/Application Support/reginald/plugins` and
  `~/.local/share/reginald/plugins`.
- Windows: `%LOCALAPPDATA%/reginald/plugins`.
- Linux (and every other platform): `~/.local/share/reginald/plugins`.

The user define their own search paths using the `--plugin-paths` command-line
option and the `plugin-paths` config option.

Each plugin should be in a search directory in a directory that matches the
plugin’s name. That directory must contain the plugin manifest as a JSON file
called `reginald-plugin.json` and the file that should be executed. If
`reginald-plugin.json` does not define additional information on the plugin’s
executable (see [Plugin manifest](#plugin-manifest) for more information),
Reginald tries to execute the plugin by running it from a file that has the same
name as the plugin without any file extension. The file should exist and the
user running Reginald should have permission to execute it.

## Plugin manifest

The plugin manifest is a JSON file in the plugin directory called
`reginald-plugin.json`. The plugin manifest is a small file that tells Reginald
how to run the plugin. The rest of the plugins capabilities and more detailed
information about the plugin are provided by the plugin when it is run.

The fields in the file are documented below:

| Field name | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Type                                     | Required                  |
| :--------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------- | :------------------------ |
| name       | The name of the plugin. This must match the name of the directory that the plugin is in and, if no entry point name is defined, also the name of the executable file.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | `string`                                 | yes                       |
| type       | The executable type of the plugin, can be either `"standalone"` or `"runtime"`. If the type is `"standalone"`, Reginald assumes that the plugin does not require a runtime and that the plugin can be executed from the command as is. Setting the type to `"runtime"` means that the plugin requires an external runtime to run the executable, e.g. Python or Node.js. If `type` is omitted, it is assumed to be `"standalone"`.                                                                                                                                                                                                                                                                                                                                                            | `"standalone"` or `"runtime"` (`string`) | no                        |
| exec       | The name of the executable that is used to run the plugin. This must be the name of the executable file in the plugin’s directory, meaning the same the directory that the manifest is in. If it is omitted, `name` is used as the name of the executable file.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | `string`                                 | no                        |
| runtime    | If the plugin requires an external runtime, `runtime` should contain that runtime’s name. The name must match one that is provided by a plugin or that is configured in `[runtime]` table in the config file. If no matching runtime is found, Reginald will fail when no plugin provides installation of that runtime. Otherwise, Reginald will install the runtime with a task before executing this plugin.                                                                                                                                                                                                                                                                                                                                                                                | `string`                                 | for `runtime` type plugin |
| args       | The format and arguments that the plugin executable should be run with as an array of the arguments. To use the plugin’s executable in the array, use the `"$EXEC"` token, and to use the executable that is resolved for the runtime that is defined for the plugin, use the `"$RUNTIME"` token. The first element must be either `"$EXEC"` or `"$RUNTIME"`, and Reginald refuses to spawn anything else as the plugin child process. If the plugin is `standalone`, the `"$RUNTIME"` token may not be used. Please note that if the plugin requires a runtime, the `"$RUNTIME"` token is not required. The `"$EXEC"` token must be present in the array. If `args` is omitted, the default value is `["$EXEC"]` for `standalone` plugins and `["$RUNTIME", "$EXEC"]` for `runtime` plugins. | `string[]`                               | no                        |

## Plugin runtime

As plugins are external executables that Reginald runs as child processes, they
can require an external runtime.
