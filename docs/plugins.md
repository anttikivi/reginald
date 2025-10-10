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

| Field name | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Type                          | Required |
| :--------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------------------------- | :------- |
| name       | The name of the plugin. This must match the name of the directory that the plugin is in and, if no entry point name is defined, also the name of the executable file.                                                                                                                                                                                                                                                                                                                          | `string`                      | yes      |
| entrypoint | Configuration for running the plugin. If `entrypoint` is not given or it is `null`, the `type` of the `entrypoint` is assumed to be `executable` and the `command` is `./<plugin name>`. If the `entrypoint` is given as a string, the `type` of the `entrypoint` is assumed to be `executable` and the given string is interpreted as the `command`. Additional configuration can be given as an object value for the `entrypoint` field. Documentation for the object is in the table below. | `null`, `string`, or `object` | no       |

Documentation for `entrypoint`’s object value:

| Field name | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Type                                     | Required |
| :--------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :--------------------------------------- | :------- |
| type       | The executable type of the plugin, can be either `"executable"` or `"runtime"`. If the type is `"executable"`, Reginald assumes that the plugin does not require a runtime and that the plugin can be executed from the command as is. If the type is `"runtime"`, the plugin requires an external runtime to run the command, e.g. Python or Node.js. If `type` is omitted, it is assumed to be `"executable"`.                                                                                                                                                                                                                                                                                                       | `"executable"` or `"runtime"` (`string`) | no       |
| runtime    | If the plugin requires an external runtime, `runtime` should contain that runtime’s name. The name must match one that is provided by a plugin or that is configured in `[runtime]` table in the config file. If no matching runtime is found, Reginald will fail when no plugin provides installation of that runtime. Otherwise, Reginald will install the runtime with a task before executing this plugin.                                                                                                                                                                                                                                                                                                         | `string`                                 | no       |
| command    | The command that is used to run the plugin as an array of arguments. The first argument is the command to run. The command is resolved relative to the plugin’s directory so that, for example, command `./example-plugin` would run the plugin executable named `example-plugin` from the plugin directory. If the plugin requires a runtime, this must be the full command to run the plugin with the required runtime. To use the full executable file in the arguments, use the placeholder `"$0"` and to use the resolved runtime executable, use the placeholder `"$1"`. If `command` is omitted, for executable-type plugins the command is assumed to be `["$0"]` and for runtime-type plugins `["$1", "$0"]`. | `array`                                  | no       |

## Plugin runtime

As plugins are external executables that Reginald runs as child processes
