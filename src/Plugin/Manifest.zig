//! A plugin manifest. The manifests are initialized with `loadAll`, and all of
//! the initialized manifests must be freed by calling `deinit` on them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Config = @import("../Config.zig");
const core = @import("core.zig");
const output = @import("../output.zig");

const Manifest = @This();

const plugin_log = std.log.scoped(.plugin);

/// The name of the static manifest files.
const manifest_file_name = "reginald-plugin.json";

/// The name of the plugin as reported in the manifest.
name: []const u8,

/// The type of the plugin executable as reported in the manifest.
type: PluginType = .standalone,

/// The name of the executable file in the plugin's directory that is used as
/// the plugin.
exec: []const u8 = "",

/// The name of the external runtime that the plugin required.
runtime: ?[]const u8 = null,

/// The arguments that are used to run the plugin process.
args: []const []const u8 = &.{},

/// The computed path to the plugin's directory that contains the manifest file.
/// It may only be null for the core plugins. The path is relative to
/// the configured base directory. This field is internal and setting it in
/// the manifest file will result in an error.
path: ?[]const u8 = null,

pub const PluginType = enum { core, standalone, runtime };

pub fn deinit(self: *Manifest, gpa: Allocator) void {
    if (self.type == .core) {
        return;
    }

    if (self.path) |p| {
        gpa.free(p);
    }

    for (self.args) |arg| {
        gpa.free(arg);
    }
    gpa.free(self.args);

    if (self.runtime) |r| {
        gpa.free(r);
    }

    if (!std.mem.eql(u8, self.exec, self.name)) {
        gpa.free(self.exec);
    }

    gpa.free(self.name);
}

/// Find all of the plugin manifest files in the plugin search paths and load
/// them.
pub fn loadAll(gpa: Allocator, cfg: *const Config, dir: std.fs.Dir) ![]Manifest {
    var manifests: ArrayList(Manifest) = .empty;
    errdefer manifests.deinit(gpa);
    errdefer for (manifests.items) |*m| {
        m.deinit(gpa);
    };

    try manifests.appendSlice(gpa, &core.manifests);

    const paths = cfg.get([]const []const u8, "plugin_paths") orelse &[_][]u8{};
    for (paths) |search_path| {
        plugin_log.debug("searching for plugins from \"{s}\"", .{search_path});

        var plugins_dir = try dir.openDir(search_path, .{});
        defer plugins_dir.close();

        var walker = try plugins_dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (!std.mem.eql(u8, manifest_file_name, entry.basename)) {
                continue;
            }

            const full_path = try std.fs.path.resolve(gpa, &.{ search_path, entry.path });
            defer gpa.free(full_path);

            plugin_log.debug("found a plugin manifest at \"{s}\"", .{full_path});

            var file = entry.dir.openFile(entry.basename, .{ .mode = .read_only }) catch |err| {
                try output.discard(
                    "failed to open plugin manifest file at \"{s}\": {t}\nskipping the plugin...",
                    .{ full_path, err },
                );
                continue;
            };
            defer file.close();

            var file_buffer: [128]u8 = undefined;
            var file_reader = file.reader(&file_buffer);
            const file_data = try (&file_reader.interface).allocRemaining(gpa, .unlimited);
            defer gpa.free(file_data);

            var scanner: std.json.Scanner = .initCompleteInput(gpa, file_data);
            defer scanner.deinit();

            var diagnostics = std.json.Diagnostics{};
            scanner.enableDiagnostics(&diagnostics);

            const parsed = std.json.parseFromTokenSource(Manifest, gpa, &scanner, .{}) catch |err| {
                const offset = diagnostics.getByteOffset();
                const start = std.mem.lastIndexOfScalar(u8, file_data[0..offset], '\n') orelse 0;
                const end = std.mem.indexOfScalarPos(u8, file_data, offset, '\n') orelse file_data.len;
                const snippet = file_data[(if (start > 0) start + 1 else start)..end];

                var stderr_buffer: [256]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
                var stderr = &stderr_writer.interface;

                try stderr.print(
                    "error parsing plugin manifest file at \"{s}\" on line {d}, column {d}:\n",
                    .{ full_path, diagnostics.getLine(), diagnostics.getColumn() },
                );

                try stderr.writeAll(snippet);
                try stderr.writeByte('\n');

                switch (err) {
                    error.UnknownField => {
                        var i: usize = 0;

                        while (i < snippet.len) : (i += 1) {
                            switch (snippet[i]) {
                                ' ', '\t' => {},
                                else => break,
                            }
                        }

                        const ws = snippet[0..i];

                        try stderr.writeAll(ws);
                        try stderr.splatByteAll('~', diagnostics.getColumn() - 1 - ws.len);
                    },
                    else => try stderr.splatByteAll(' ', diagnostics.getColumn() - 1),
                }

                try stderr.writeByte('^');
                try stderr.writeByte(' ');

                switch (err) {
                    error.SyntaxError => try stderr.writeAll("syntax error"),
                    error.UnknownField => try stderr.writeAll("unknown field"),
                    else => try stderr.writeAll(@errorName(err)),
                }

                try stderr.writeByte('\n');
                try stderr.writeByte('\n');
                try stderr.flush();

                return error.Reported;
            };
            defer parsed.deinit();

            if (parsed.value.path) |p| {
                return output.fail("internal manifest field path set in the manifest file: \"{s}\"", .{p});
            }

            if (parsed.value.type == .core) {
                return output.fail("plugin \"{s}\" has invalid type: {t}", .{
                    parsed.value.name,
                    parsed.value.type,
                });
            } else if (parsed.value.type == .runtime and parsed.value.runtime == null) {
                return output.fail(
                    "type for plugin \"{s}\" is set to \"{t}\" but no runtime name was provided in the manifest file",
                    .{
                        parsed.value.name,
                        parsed.value.type,
                    },
                );
            }

            var manifest: Manifest = .{
                .name = try gpa.dupe(u8, parsed.value.name),
                .type = parsed.value.type,
            };
            errdefer gpa.free(manifest.name);

            if (parsed.value.exec.len == 0 or std.mem.eql(u8, parsed.value.exec, manifest.name)) {
                manifest.exec = manifest.name;
            } else {
                manifest.exec = try gpa.dupe(u8, parsed.value.exec);
            }
            errdefer if (!std.mem.eql(u8, manifest.exec, manifest.name)) {
                gpa.free(manifest.exec);
            };

            if (parsed.value.runtime) |r| {
                manifest.runtime = try gpa.dupe(u8, r);
            }
            errdefer if (manifest.runtime) |r| {
                gpa.free(r);
            };

            if (parsed.value.args.len == 0) {
                switch (manifest.type) {
                    .standalone => {
                        var args = try gpa.alloc([]u8, 1);
                        args[0] = try gpa.dupe(u8, "$EXEC");
                        manifest.args = args;
                    },
                    .runtime => {
                        var args = try gpa.alloc([]u8, 2);
                        args[0] = try gpa.dupe(u8, "$RUNTIME");
                        args[1] = try gpa.dupe(u8, "$EXEC");
                        manifest.args = args;
                    },
                    .core => unreachable,
                }
            } else {
                var args = try gpa.alloc([]u8, parsed.value.args.len);

                for (parsed.value.args, 0..) |arg, i| {
                    args[i] = try gpa.dupe(u8, arg);
                }

                manifest.args = args;
            }
            errdefer {
                for (manifest.args) |arg| {
                    gpa.free(arg);
                }
                gpa.free(manifest.args);
            }

            manifest.path = try gpa.dupe(u8, std.fs.path.dirname(full_path) orelse ".");
            errdefer gpa.free(manifest.path.?);

            try manifests.append(gpa, manifest);

            plugin_log.debug("parsed manifest for \"{s}\": {f}", .{
                manifest.name,
                std.json.fmt(manifest, .{}),
            });
        }
    }

    return manifests.toOwnedSlice(gpa);
}
