const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Config = @import("Config.zig");
const Metadata = Config.Metadata;

/// Subcommands available in Reginald.
const Subcommand = enum {
    none,
    apply,
};

/// Value of a parsed command-line option.
const OptionValue = union(enum) {
    bool: bool,
    int: i64,
    string: []const u8,
};

/// Result of the command-line argument parser.
const Parsed = struct {
    allocator: Allocator,

    /// The arguments remaining after parsing when unknown arguments don't make
    /// the parser return an error.
    args: [][]const u8,
    subcommand: Subcommand,

    /// Values of the command-line options that were found and parsed
    /// successfully. The values are stored by the name of the config option
    /// that is read from the metadata.
    values: std.StringHashMap(OptionValue),

    pub fn deinit(self: *@This()) !void {
        self.allocator.free(self.args);
        try self.values.deinit();
    }
};

/// Parse command-line arguments in a lax manner so that unknown arguments are
/// ignored. This should be used for parsing the command-line arguments during
/// the first run when the options and subcommands that the plugins provide are
/// not known.
///
/// The writer must be a writer, and it is used for printing more detailed error
/// messages if the function encounters invalid arguments.
pub fn parseArgsLaxly(allocator: Allocator, args: []const []const u8, writer: anytype) !Parsed {
    var subcommand: Subcommand = .none;
    var unknown = std.ArrayList([]const u8).init(allocator);
    errdefer unknown.deinit();

    var values = std.StringHashMap(OptionValue).init(allocator);
    errdefer values.deinit();

    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];
        assert(arg.len > 0);

        if (std.mem.startsWith(u8, arg, "--")) {
            if (arg.len == 2) {
                break;
            }

            const long = if (std.mem.indexOfScalarPos(u8, arg, 2, '=')) |j| arg[2..j] else arg[2..];
            const option_meta = optionMetadataForLong(long) orelse {
                try unknown.append(arg);
                continue;
            };

            if (values.contains(option_meta.name)) {
                try writer.print("option `--{s}` can be specified only once\n", .{long});
                return error.InvalidArgs;
            }

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
                        // TODO: Maybe add more sophisticated string parsing so
                        // that the user cannot actually include more quotes
                        // inside the quotes.
                        if (arg[long.len + 3] == '"' and arg[arg.len - 1] == '"') {
                            try values.put(option_meta.name, .{ .string = arg[long.len + 4 .. arg.len - 1] });
                            break :blk 0;
                        }

                        try values.put(option_meta.name, .{ .string = arg[long.len + 3 ..] });
                        break :blk 0;
                    }

                    if (i + 1 >= args.len) {
                        try writer.print("option `--{s}` requires a value\n", .{long});
                        return error.InvalidArgs;
                    }

                    try values.put(option_meta.name, .{ .string = args[i + 1] });
                    break :blk 1;
                },
            };

            continue;
        }

        if (arg[0] == '-' and arg.len > 1) {
            var rest: ?std.ArrayList(u8) = null;
            defer if (rest) |list| {
                list.deinit();
            };

            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];

                if (c == '=') {
                    if (rest) |*list| {
                        try list.appendSlice(arg[j..]);
                    } else {
                        try writer.print("unexpected value separator in `{s}`\n", .{arg});
                        return error.InvalidArgs;
                    }

                    break;
                }

                const option_meta = optionMetadataForShort(c) orelse {
                    if (rest) |*list| {
                        try list.append(c);
                    } else {
                        rest = .init(allocator);
                        try rest.?.appendSlice(&[_]u8{ '-', c });
                    }

                    continue;
                };

                if (values.contains(option_meta.name)) {
                    try writer.print("option `-{c}` can be specified only once\n", .{c});
                    return error.InvalidArgs;
                }

                switch (try Config.valueType(option_meta)) {
                    .bool => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const b = Config.parseBool(arg[j + 2 ..]) catch {
                                try writer.print("invalid value for option `-{c}` in `{s}`: {s}\n", .{ c, arg, arg[j + 2 ..] });
                                return error.InvalidArgs;
                            };

                            try values.put(option_meta.name, .{ .bool = b });
                            continue :outer;
                        }

                        try values.put(option_meta.name, .{ .bool = true });
                    },
                    .int => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const n = std.fmt.parseInt(i64, arg[j + 2 ..], 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, arg[j + 2 ..] });
                                return error.InvalidArgs;
                            };

                            try values.put(option_meta.name, .{ .int = n });
                            continue :outer;
                        }

                        if (arg.len > j + 1) {
                            const n = std.fmt.parseInt(i64, arg[j + 1 ..], 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, arg[j + 1 ..] });
                                return error.InvalidArgs;
                            };

                            try values.put(option_meta.name, .{ .int = n });

                            continue :outer;
                        }

                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});

                            return error.InvalidArgs;
                        }

                        i += 1;

                        const n = std.fmt.parseInt(i64, args[i], 0) catch {
                            try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, args[i] });
                            return error.InvalidArgs;
                        };

                        try values.put(option_meta.name, .{ .int = n });
                        continue :outer;
                    },
                    .string => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            // TODO: Maybe add more sophisticated string parsing
                            // so that the user cannot actually include more
                            // quotes inside the quotes.
                            if (arg[j + 2] == '"' and arg[arg.len - 1] == '"') {
                                try values.put(option_meta.name, .{ .string = arg[j + 3 .. arg.len - 1] });
                                continue :outer;
                            }

                            try values.put(option_meta.name, .{ .string = arg[j + 2 ..] });
                            continue :outer;
                        }

                        if (arg.len > j + 1) {
                            // TODO: Maybe add more sophisticated string parsing
                            // so that the user cannot actually include more
                            // quotes inside the quotes.
                            if (arg[j + 1] == '"' and arg[arg.len - 1] == '"') {
                                try values.put(option_meta.name, .{ .string = arg[j + 2 .. arg.len - 1] });
                                continue :outer;
                            }

                            // TODO: This has good potential for bugs or simply
                            // confusion as we check the next characters for
                            // the string value for the option.
                            try values.put(option_meta.name, .{ .string = arg[j + 1 ..] });
                            continue :outer;
                        }

                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});
                            return error.InvalidArgs;
                        }

                        i += 1;

                        try values.put(option_meta.name, .{ .string = args[i] });
                        continue :outer;
                    },
                }
            }

            if (rest) |*list| {
                try unknown.append(try list.toOwnedSlice());
            }

            continue;
        }

        if (std.meta.stringToEnum(Subcommand, arg)) |tag| {
            switch (tag) {
                .apply => subcommand = .apply,
                .none => {
                    try writer.print("unknown command `{s}`\n", .{arg});
                    return error.InvalidArgs;
                },
            }
        } else {
            try unknown.append(arg);
        }
    }

    return .{
        .allocator = allocator,
        .args = try unknown.toOwnedSlice(),
        .subcommand = subcommand,
        .values = values,
    };
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

/// Look up the config option metadata with the given short, one-letter
/// command-line option name.
fn optionMetadataForShort(short: u8) ?Metadata {
    for (Config.metadata) |m| {
        if (m.short) |c| {
            if (c == short) {
                return m;
            }
        }
    }

    return null;
}
