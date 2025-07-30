const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Config = @import("Config.zig");
const Metadata = Config.Metadata;

/// Value of a parsed command-line option.
const OptionValue = union(enum) {
    bool: bool,
    int: i64,
    string: []const u8,
};

/// Result of the command-line argument parser.
const Parsed = struct {
    allocator: Allocator,

    /// Values of the command-line options that were found and parsed
    /// successfully. The values are stored by the name of the config option
    /// that is read from the metadata.
    values: std.StringHashMap(OptionValue),

    pub fn deinit() void {}
};

/// Parse command-line arguments in a lax manner so that unknown arguments are
/// ignored. This should be used for parsing the command-line arguments during
/// the first run when the options and subcommands that the plugins provide are
/// not known.
///
/// The writer must be a writer, and it is used for printing more detailed error
/// messages if the function encounters invalid arguments.
pub fn parseArgsLaxly(allocator: Allocator, args: []const []const u8, writer: anytype) !void {
    var left = std.ArrayList([]const u8).init(allocator);
    errdefer left.deinit();

    var values = std.StringHashMap(OptionValue).init(allocator);
    errdefer values.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        assert(arg.len > 0);

        if (std.mem.startsWith(u8, arg, "--")) {
            if (arg.len == 2) {
                break;
            }

            const long = if (std.mem.indexOfScalarPos(u8, arg, 2, '=')) |j| arg[2..j] else arg[2..];
            const option_meta = optionMetadataForLong(long) orelse {
                try left.append(arg);
                continue;
            };

            i += blk: switch (try Config.valueType(option_meta)) {
                .bool => {
                    if (std.mem.eql(u8, arg[2..], long)) {
                        try values.put(option_meta.name, .{ .bool = true });
                        break :blk 0;
                    }

                    const b = Config.parseBool(arg[long.len + 3 ..]) catch {
                        try writer.print("invalid value for option `--{s}`: {s}\n", .{ long, arg[long.len + 3 ..] });
                        return error.InvalidArgs;
                    };

                    try values.put(option_meta.name, .{ .bool = b });
                    break :blk 0;
                },
                .int => {
                    if (!std.mem.eql(u8, arg[2..], long)) {
                        const n = std.fmt.parseInt(i64, arg[long.len + 3 ..], 0) catch {
                            try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ long, arg[long.len + 3 ..] });
                            return error.InvalidArgs;
                        };

                        try values.put(option_meta.name, .{ .int = n });
                        break :blk 0;
                    }

                    if (i + 1 >= args.len) {
                        try writer.print("option `--{s}` requires a value", .{long});
                        return error.InvalidArgs;
                    }

                    const n = std.fmt.parseInt(i64, args[i + 1], 0) catch {
                        try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ long, args[i + 1] });
                        return error.InvalidArgs;
                    };

                    try values.put(option_meta.name, .{ .int = n });
                    break :blk 1;
                },
                .string => {
                    if (!std.mem.eql(u8, arg[2..], long)) {
                        if (arg[long.len + 3] == '"' and arg[arg.len - 1] == '"') {
                            try values.put(option_meta.name, .{ .string = arg[long.len + 4 .. arg.len - 1] });
                            break :blk 0;
                        }

                        try values.put(option_meta.name, .{ .string = arg[long.len + 3 .. arg.len - 1] });
                        break :blk 0;
                    }

                    if (i + 1 >= args.len) {
                        try writer.print("option `--{s}` requires a value", .{long});
                        return error.InvalidArgs;
                    }

                    try values.put(option_meta.name, .{ .string = args[i + 1] });
                    break :blk 1;
                },
            };

            continue;
        }
    }
}

/// Look up the config option metadata with the given long command-line option
/// name.
fn optionMetadataForLong(name: []const u8) ?Metadata {
    for (Config.metadata) |m| {
        if (m.long) |long| {
            if (std.mem.eql(u8, long, name)) {
                return m;
            }
        } else if (std.mem.eql(u8, m.name, name)) {
            return m;
        }
    }

    return null;
}
