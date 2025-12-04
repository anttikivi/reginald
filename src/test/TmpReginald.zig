//! TmpReginald is an utility for integration tests, which runs Reginald in
//! a temporary directory and first builds it, if needed.

// This file is originally from TigerBeetle
// (https://github.com/tigerbeetle/tigerbeetle), licensed under the Apache
// License, Version 2.0. It is modified by Antti Kivi. See THIRD_PARTY_NOTICES
// for more information.

const TmpReginald = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.tmp_reginald);

const Shell = @import("Shell.zig");
const units = @import("units");
const mib = units.mib;

/// Path to the executable.
reginald_exe: []const u8,

tmp_dir: std.testing.TmpDir,

pub fn init(
    gpa: Allocator,
    shell: *Shell,
    comptime options: struct {
        flat: bool = false,
        log_level: ?std.log.Level = null,
        prebuilt: ?[]const u8 = null,
    },
) !TmpReginald {
    var from_source_path: ?[]const u8 = null;
    defer if (from_source_path) |path| gpa.free(path);

    if (options.prebuilt == null) {
        const cmd = "build --prefix ./zig-out" ++ (if (options.log_level) |l|
            " -Dlog-level=" ++ @tagName(l)
        else
            "") ++ (if (options.flat) " -Dflat" else "");

        // If reginald binary does not exist yet, build it.
        try shell.execZig(cmd, .{});

        const reginald_exe = if (options.flat)
            comptime "zig-out/reginald" ++ builtin.target.exeFileExt()
        else
            comptime "zig-out/bin/reginald" ++ builtin.target.exeFileExt();

        from_source_path = try shell.project_root.realpathAlloc(gpa, reginald_exe);
    }

    const reginald_exe: []const u8 = try gpa.dupe(
        u8,
        options.prebuilt orelse from_source_path.?,
    );
    errdefer gpa.free(reginald_exe);
    assert(std.fs.path.isAbsolute(reginald_exe));

    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const tmp_dir_path = try tmp_dir.dir.realpathAlloc(gpa, ".");
    defer gpa.free(tmp_dir_path);

    return .{
        .reginald_exe = reginald_exe,
        .tmp_dir = tmp_dir,
    };
}

pub fn deinit(self: *TmpReginald, gpa: Allocator) void {
    self.tmp_dir.cleanup();
    gpa.free(self.reginald_exe);
}
