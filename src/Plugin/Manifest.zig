//! A plugin manifest. The manifests are initialized with `loadAll`, and all of
//! the initialized manifests must be freed by calling `deinit` on them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const StringHashMap = std.StringHashMap;

const Config = @import("../Config.zig");
const core = @import("core.zig");
const output = @import("../output.zig");
const Plugin = @import("../Plugin.zig");

const Manifest = @This();

const plugin_log = std.log.scoped(.plugin);

/// The name of the static manifest files.
const manifest_file_name = "reginald-plugin.json";

/// The manifest version. It won't be required for at least the development
/// versions of the manifests.
version: u8 = 0,

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

/// The namespace that the plugin uses. It's either the name of the plugin or
/// the part of the plugin's name that comes after `Plugin.prefix`.
namespace: []const u8 = "",

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

pub fn format(self: Manifest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(self, .{ .whitespace = .indent_2 }, writer);
}

/// Find all of the plugin manifest files in the plugin search paths and load
/// them.
pub fn loadAll(gpa: Allocator, cfg: *const Config, dir: std.fs.Dir) ![]Manifest {
    var manifests: ArrayList(Manifest) = .empty;
    errdefer manifests.deinit(gpa);
    errdefer for (manifests.items) |*m| {
        m.deinit(gpa);
    };

    var seen_names: StringHashMap(void) = .init(gpa);
    defer seen_names.deinit();

    var seen_namespaces: StringHashMap(void) = .init(gpa);
    defer seen_namespaces.deinit();

    inline for (core.manifests) |m| {
        assert(std.mem.startsWith(u8, m.name, Plugin.prefix));
        assert(std.mem.eql(u8, m.namespace, m.name[Plugin.prefix.len..]));
        assert(m.type == .core);

        assert(!seen_names.contains(m.name));
        try seen_names.put(m.name, {});

        assert(!seen_namespaces.contains(m.namespace));
        try seen_namespaces.put(m.namespace, {});

        try manifests.append(gpa, m);

        plugin_log.debug("loaded manifest for \"{s}\": {f}", .{ m.name, m });
    }

    const paths = cfg.get([]const []const u8, "plugin_paths") orelse {
        return output.fail("no plugin search paths configured", .{});
    };
    for (paths) |search_path| {
        plugin_log.debug("searching for plugins from \"{s}\"", .{search_path});

        var search_dir = try dir.openDir(search_path, .{});
        defer search_dir.close();

        var walker = try search_dir.walk(gpa);
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

            var manifest = parseManifest(gpa, file_data, full_path) catch |err| switch (err) {
                error.Reported => return err,
                else => return output.fail(
                    "failed to parse plugin manifest at \"{s}\": {t}",
                    .{ full_path, err },
                ),
            };
            errdefer manifest.deinit(gpa);

            if (seen_names.contains(manifest.name)) {
                return output.fail("duplicate plugin name: {s}", .{manifest.name});
            }

            try seen_names.put(manifest.name, {});

            if (seen_namespaces.contains(manifest.namespace)) {
                return output.fail("duplicate plugin namespace: {s}", .{manifest.name});
            }

            try seen_namespaces.put(manifest.namespace, {});

            try manifests.append(gpa, manifest);
        }
    }

    return manifests.toOwnedSlice(gpa);
}

fn parseManifest(gpa: Allocator, data: []const u8, path: []const u8) !Manifest {
    assert(data.len > 0);
    assert(path.len > 0);

    var scanner: std.json.Scanner = .initCompleteInput(gpa, data);
    defer scanner.deinit();

    var diagnostics = std.json.Diagnostics{};
    scanner.enableDiagnostics(&diagnostics);

    const parsed = std.json.parseFromTokenSource(Manifest, gpa, &scanner, .{}) catch |err| {
        const offset = diagnostics.getByteOffset();
        const start = std.mem.lastIndexOfScalar(u8, data[0..offset], '\n') orelse 0;
        const end = std.mem.indexOfScalarPos(u8, data, offset, '\n') orelse data.len;
        const snippet = data[(if (start > 0) start + 1 else start)..end];

        var stderr_buffer: [256]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        var stderr = &stderr_writer.interface;

        try stderr.print(
            "error parsing plugin manifest file at \"{s}\" on line {d}, column {d}:\n",
            .{ path, diagnostics.getLine(), diagnostics.getColumn() },
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

    if (parsed.value.namespace.len != 0) {
        return output.fail(
            "internal manifest field \"namespace\" set in the manifest file: \"{s}\"",
            .{parsed.value.namespace},
        );
    }

    if (parsed.value.path) |p| {
        return output.fail(
            "internal manifest field \"path\" set in the manifest file: \"{s}\"",
            .{p},
        );
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
                args[0] = try gpa.dupe(u8, Plugin.exec_token);
                manifest.args = args;
            },
            .runtime => {
                var args = try gpa.alloc([]u8, 2);
                args[0] = try gpa.dupe(u8, Plugin.runtime_token);
                args[1] = try gpa.dupe(u8, Plugin.exec_token);
                manifest.args = args;
            },
            .core => unreachable,
        }
    } else {
        try validateArgs(parsed.value.args, &manifest);

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

    manifest.namespace = if (std.mem.startsWith(u8, manifest.name, Plugin.prefix)) blk: {
        break :blk manifest.name[Plugin.prefix.len..];
    } else manifest.name;

    manifest.path = try gpa.dupe(
        u8,
        std.fs.path.dirname(path) orelse return output.fail(
            "path of plugin \"{s}\" is not a subdirectory of any plugin search path",
            .{manifest.name},
        ),
    );
    errdefer gpa.free(manifest.path.?);

    plugin_log.debug("parsed manifest for \"{s}\": {f}", .{ manifest.name, manifest });

    const dir_name = std.fs.path.basename(manifest.path.?);
    if (!std.mem.eql(u8, dir_name, manifest.name) and !std.mem.eql(u8, dir_name, manifest.namespace)) {
        return output.fail("name of the directory for plugin \"{s}\" does not match the plugin's name or namespace: {s}", .{ manifest.name, dir_name });
    }

    return manifest;
}

fn validateArgs(args: []const []const u8, manifest: *const Manifest) !void {
    if (!std.mem.eql(u8, args[0], Plugin.exec_token) and !std.mem.eql(u8, args[0], Plugin.runtime_token)) {
        return output.fail(
            "run arguments for plugin \"{s}\" starts with an invalid token: {s}",
            .{ manifest.name, args[0] },
        );
    }

    var found_exec = false;
    for (args) |arg| {
        if (manifest.type != .runtime and std.mem.eql(u8, Plugin.runtime_token, arg)) {
            return output.fail(
                "run arguments for plugin \"{s}\" include the runtime token \"{s}\" even though the plugin does not use an external runtime",
                .{ manifest.name, Plugin.runtime_token },
            );
        }

        if (std.mem.eql(u8, Plugin.exec_token, arg)) {
            found_exec = true;
        }
    }

    if (!found_exec) {
        return output.fail(
            "run arguments for plugin \"{s}\" do not include the executable token \"{s}\"",
            .{ manifest.name, Plugin.exec_token },
        );
    }
}
