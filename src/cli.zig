const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;
const meta = std.meta;
const StructField = std.builtin.Type.StructField;
const testing = std.testing;

const Config = @import("Config.zig");

/// Value of a parsed command-line option.
const OptionValue = union(Config.OptionType) {
    bool: bool,
    int: i64,
    string: []const u8,
};

/// Result of the command-line argument parser.
pub const Parsed = struct {
    allocator: Allocator,

    /// The arguments remaining after parsing when unknown arguments don't make
    /// the parser return an error.
    args: [][]const u8,
    // subcommand: Subcommand,

    /// Values of the command-line options that were found and parsed
    /// successfully. The values are stored by the name of the config option
    /// that is read from the metadata.
    values: std.StringHashMap(OptionValue),

    pub fn deinit(self: *@This()) void {
        for (self.args) |s| {
            self.allocator.free(s);
        }
        self.allocator.free(self.args);
        self.values.deinit();
    }
};

const OnUnknown = enum { fail, skip };

/// Parse command-line arguments and fail on unknown arguments. The writer is
/// used for printing more detailed error messages if the function encounters
/// invalid arguments.
///
/// The arguments passed in to the function must not contain the the name of
/// the program.
pub fn parseArgs(allocator: Allocator, args: []const []const u8, writer: anytype) !Parsed {
    return parseArgsWithOptions(allocator, .fail, args, writer);
}

/// Parse command-line arguments in a lax manner so that unknown arguments are
/// ignored. This should be used for parsing the command-line arguments during
/// the first run when the options and subcommands that the plugins provide are
/// not known.
///
/// The arguments passed in to the function must not contain the the name of
/// the program.
///
/// The writer is used for printing more detailed error messages if the function
/// encounters invalid arguments.
pub fn parseArgsLaxly(allocator: Allocator, args: []const []const u8, writer: anytype) !Parsed {
    return parseArgsWithOptions(allocator, .skip, args, writer);
}

/// Implementation for parsing arguments.
///
/// TODO: If there are many unknown arguments, there is a lot of duplicating. It
/// might be worth considering if the parser would benefit from reduced
/// allocations.
fn parseArgsWithOptions(
    allocator: Allocator,
    comptime on_unknown: OnUnknown,
    args: []const []const u8,
    writer: anytype,
) !Parsed {
    // const subcommand: ?[]const u8 = null;
    var unknown: std.ArrayList([]const u8) = switch (on_unknown) {
        .fail => undefined,
        .skip => .init(allocator),
    };
    errdefer switch (on_unknown) {
        .fail => {},
        .skip => unknown.deinit(),
    };

    var values: std.StringHashMap(OptionValue) = .init(allocator);
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
            const option_name = configNameFromLong(long) orelse switch (on_unknown) {
                .fail => {
                    try writer.print("invalid command-line option `--{s}`\n", .{long});
                    return error.InvalidArgs;
                },
                .skip => {
                    try unknown.append(try allocator.dupe(u8, arg));
                    continue;
                },
            };

            if (values.contains(option_name)) {
                try writer.print("option `--{s}` can be specified only once\n", .{long});
                return error.InvalidArgs;
            }

            i += blk: switch ((try Config.optionType(option_name)).?) {
                .bool => {
                    if (std.mem.eql(u8, arg[2..], long)) {
                        try values.put(option_name, .{ .bool = true });
                        break :blk 0;
                    }

                    const b = Config.parseBool(arg[long.len + 3 ..]) catch {
                        try writer.print("invalid value for option `--{s}`: {s}\n", .{ long, arg[long.len + 3 ..] });
                        return error.InvalidArgs;
                    };

                    try values.put(option_name, .{ .bool = b });
                    break :blk 0;
                },
                .int => {
                    if (!std.mem.eql(u8, arg[2..], long)) {
                        const n = std.fmt.parseInt(i64, arg[long.len + 3 ..], 0) catch {
                            try writer.print("value for option `--{s}` is not an integer: {s}\n", .{ long, arg[long.len + 3 ..] });
                            return error.InvalidArgs;
                        };

                        try values.put(option_name, .{ .int = n });
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

                    try values.put(option_name, .{ .int = n });
                    break :blk 1;
                },
                .string => {
                    if (!std.mem.eql(u8, arg[2..], long)) {
                        // TODO: Maybe add more sophisticated string parsing so
                        // that the user cannot actually include more quotes
                        // inside the quotes.
                        if (arg[long.len + 3] == '"' and arg[arg.len - 1] == '"') {
                            try values.put(option_name, .{ .string = arg[long.len + 4 .. arg.len - 1] });
                            break :blk 0;
                        }

                        try values.put(option_name, .{ .string = arg[long.len + 3 ..] });
                        break :blk 0;
                    }

                    if (i + 1 >= args.len) {
                        try writer.print("option `--{s}` requires a value\n", .{long});
                        return error.InvalidArgs;
                    }

                    try values.put(option_name, .{ .string = args[i + 1] });
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
                    switch (on_unknown) {
                        // This error message is duplicated in order to have
                        // the compiler to inline the switch and skip the if in
                        // `skip` when the `fail` mode is selected.
                        .fail => {
                            try writer.print("unexpected value separator in `{s}`\n", .{arg});
                            return error.InvalidArgs;
                        },
                        .skip => {
                            if (rest) |*list| {
                                try list.appendSlice(arg[j..]);
                            } else {
                                try writer.print("unexpected value separator in `{s}`\n", .{arg});
                                return error.InvalidArgs;
                            }
                        },
                    }

                    break;
                }

                const option_name = configNameFromShort(c) orelse switch (on_unknown) {
                    .fail => {
                        try writer.print("unknown command-line option `-{c}` in `{s}`\n", .{ c, arg });
                        return error.InvalidArgs;
                    },
                    .skip => {
                        if (rest) |*list| {
                            try list.append(c);
                        } else {
                            rest = .init(allocator);
                            try rest.?.appendSlice(&[_]u8{ '-', c });
                        }

                        continue;
                    },
                };

                if (values.contains(option_name)) {
                    try writer.print("option `-{c}` can be specified only once\n", .{c});
                    return error.InvalidArgs;
                }

                switch ((try Config.optionType(option_name)).?) {
                    .bool => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const b = Config.parseBool(arg[j + 2 ..]) catch {
                                try writer.print("invalid value for option `-{c}` in `{s}`: {s}\n", .{ c, arg, arg[j + 2 ..] });
                                return error.InvalidArgs;
                            };

                            try values.put(option_name, .{ .bool = b });
                            continue :outer;
                        }

                        try values.put(option_name, .{ .bool = true });
                    },
                    .int => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            const n = std.fmt.parseInt(i64, arg[j + 2 ..], 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, arg[j + 2 ..] });
                                return error.InvalidArgs;
                            };

                            try values.put(option_name, .{ .int = n });
                            continue :outer;
                        }

                        if (arg.len > j + 1) {
                            const n = std.fmt.parseInt(i64, arg[j + 1 ..], 0) catch {
                                try writer.print("value for option `-{c}` is not an integer: {s}\n", .{ c, arg[j + 1 ..] });
                                return error.InvalidArgs;
                            };

                            try values.put(option_name, .{ .int = n });

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

                        try values.put(option_name, .{ .int = n });
                        continue :outer;
                    },
                    .string => {
                        if (arg.len > j + 1 and arg[j + 1] == '=') {
                            // TODO: Maybe add more sophisticated string parsing
                            // so that the user cannot actually include more
                            // quotes inside the quotes.
                            if (arg[j + 2] == '"' and arg[arg.len - 1] == '"') {
                                try values.put(option_name, .{ .string = arg[j + 3 .. arg.len - 1] });
                                continue :outer;
                            }

                            try values.put(option_name, .{ .string = arg[j + 2 ..] });
                            continue :outer;
                        }

                        if (arg.len > j + 1) {
                            // TODO: Maybe add more sophisticated string parsing
                            // so that the user cannot actually include more
                            // quotes inside the quotes.
                            if (arg[j + 1] == '"' and arg[arg.len - 1] == '"') {
                                try values.put(option_name, .{ .string = arg[j + 2 .. arg.len - 1] });
                                continue :outer;
                            }

                            // TODO: This has good potential for bugs or simply
                            // confusion as we check the next characters for
                            // the string value for the option.
                            try values.put(option_name, .{ .string = arg[j + 1 ..] });
                            continue :outer;
                        }

                        if (args.len <= i + 1) {
                            try writer.print("option `-{c}` requires a value\n", .{c});
                            return error.InvalidArgs;
                        }

                        i += 1;

                        try values.put(option_name, .{ .string = args[i] });
                        continue :outer;
                    },
                }
            }

            switch (on_unknown) {
                .fail => {},
                .skip => if (rest) |list| {
                    try unknown.append(try allocator.dupe(u8, list.items));
                },
            }

            continue;
        }

        switch (on_unknown) {
            .fail => {
                try writer.print("unknown argument: {s}\n", .{arg});
                return error.InvalidArgs;
            },
            .skip => try unknown.append(try allocator.dupe(u8, arg)),
        }

        // if (std.meta.stringToEnum(Subcommand, arg)) |tag| {
        //     switch (tag) {
        //         .apply => subcommand = .apply,
        //         .none => {
        //             try writer.print("unknown command `{s}`\n", .{arg});
        //             return error.InvalidArgs;
        //         },
        //     }
        // } else {
        //     switch (on_unknown) {
        //         .fail => {
        //             try writer.print("unknown argument: {s}\n", .{arg});
        //             return error.InvalidArgs;
        //         },
        //         .skip => try unknown.append(try allocator.dupe(u8, arg)),
        //     }
        // }
    }

    return .{
        .allocator = allocator,
        .args = switch (on_unknown) {
            .fail => try allocator.alloc([]const u8, 0), // TODO: Stupid?
            .skip => try unknown.toOwnedSlice(),
        },
        // .subcommand = subcommand,
        .values = values,
    };
}

/// Look up the config name for the given long command-line option name.
fn configNameFromLong(name: []const u8) ?[]const u8 {
    const fields: []const StructField = meta.fields(@TypeOf(Config.global_option_info));
    inline for (fields) |field| {
        switch (field.type) {
            Config.OptionInfo => {
                const info: Config.OptionInfo = @field(Config.global_option_info, field.name);
                if (info.disable_cli_option) {
                    continue;
                }

                if (info.long) |long| {
                    if (mem.eql(u8, name, long)) {
                        return field.name;
                    }
                } else if (mem.eql(u8, name, field.name)) {
                    return field.name;
                }
            },

            // We can have custom handling for all of the "custom" info types
            // (i.e. tables in config file) as we know all of the global options
            // ahead of time. There is no need to try and generalize.
            Config.LoggingInfo => {
                const logging_info: Config.LoggingInfo = @field(
                    Config.global_option_info,
                    field.name,
                );
                const logging_fields: []const StructField = meta.fields(@TypeOf(logging_info));
                inline for (logging_fields) |info_field| {
                    assert(info_field.type == Config.OptionInfo);

                    const info: Config.OptionInfo = @field(logging_info, info_field.name);
                    if (info.disable_cli_option) {
                        continue;
                    }

                    if (info.long) |long| {
                        if (mem.eql(u8, name, long)) {
                            return "logging_" ++ field.name;
                        }
                    } else if (mem.eql(u8, name, "logging-" ++ field.name)) {
                        return "logging_" ++ field.name;
                    }
                }
            },
            else => @compileError("Expected OptionInfo or LoggingInfo, found '" ++ @typeName(field.type) ++ "'"),
        }
    }

    return null;
}

/// Look up the config name for the given one-character short command-line
/// option.
fn configNameFromShort(c: u8) ?[]const u8 {
    const fields: []const StructField = meta.fields(@TypeOf(Config.global_option_info));
    inline for (fields) |field| {
        switch (field.type) {
            Config.OptionInfo => {
                const info: Config.OptionInfo = @field(Config.global_option_info, field.name);
                if (info.short) |b| {
                    if (b == c) {
                        return field.name;
                    }
                }
            },
            Config.LoggingInfo => {
                const logging_info: Config.LoggingInfo = @field(
                    Config.global_option_info,
                    field.name,
                );
                const info_fields: []const StructField = meta.fields(@TypeOf(logging_info));
                inline for (info_fields) |info_field| {
                    assert(info_field.type == Config.OptionInfo);

                    const info: Config.OptionInfo = @field(logging_info, info_field.name);
                    if (info.short) |b| {
                        if (b == c) {
                            return "logging_" ++ field.name;
                        }
                    }
                }
            },
            else => @compileError("Expected OptionInfo or LoggingInfo, found '" ++ @typeName(field.type) ++ "'"),
        }
    }

    return null;
}

test "no options" {
    const args = [_][:0]const u8{"reginald"};
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expectEqual(0, parsed.args.len);
}

test "stop parsing at `--`" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "--", "--quiet" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option" {
    const args = [_][:0]const u8{ "reginald", "--verbose" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=true" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("quiet") != null);
    try testing.expect(parsed.values.get("verbose") != null);

    try testing.expectEqual(true, parsed.values.get("quiet").?.bool);
    try testing.expectEqual(false, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option invalid value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=something" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "bool option empty value" {
    const args = [_][:0]const u8{ "reginald", "--verbose=" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "duplicate bool" {
    const args = [_][:0]const u8{ "reginald", "--quiet", "--quiet" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "string option" {
    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "multiple string options" {
    const args = [_][:0]const u8{
        "reginald",
        "--config",
        "/tmp/config.toml",
        "--directory",
        "/tmp",
    };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("directory") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqualStrings("/tmp", parsed.values.get("directory").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "string option equals sign" {
    const args = [_][:0]const u8{ "reginald", "--config=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "string option equals sign quoted" {
    const args = [_][:0]const u8{ "reginald", "--config=\"/tmp/config.toml\"" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "string option no value" {
    const args = [_][:0]const u8{ "reginald", "--config" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "bool and string option" {
    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml", "--verbose" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "string option mixed" {
    const args = [_][:0]const u8{ "reginald", "--chdir=/tmp", "--config", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("working_directory"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("working_directory") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqualStrings("/tmp", parsed.values.get("working_directory").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "invalid string order" {
    const args = [_][:0]const u8{ "reginald", "--config", "--verbose" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("--verbose", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "invalid long option" {
    const args = [_][:0]const u8{ "reginald", "--cfg" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "invalid long option 2" {
    const args = [_][:0]const u8{ "reginald", "--config_file" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "short bool option" {
    const args = [_][:0]const u8{ "reginald", "-v" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short bool option value" {
    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=true" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("quiet") != null);
    try testing.expect(parsed.values.get("verbose") != null);

    try testing.expectEqual(true, parsed.values.get("quiet").?.bool);
    try testing.expectEqual(false, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short bool option combined" {
    const args = [_][:0]const u8{ "reginald", "-qv" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("quiet") != null);
    try testing.expect(parsed.values.get("verbose") != null);

    try testing.expectEqual(true, parsed.values.get("quiet").?.bool);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short bool option combined last value" {
    const args = [_][:0]const u8{ "reginald", "-qv=false" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("quiet") != null);
    try testing.expect(parsed.values.get("verbose") != null);

    try testing.expectEqual(true, parsed.values.get("quiet").?.bool);
    try testing.expectEqual(false, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short bool option invalid value" {
    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=something" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "short bool option empty value" {
    const args = [_][:0]const u8{ "reginald", "-v=" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "short string option" {
    const args = [_][:0]const u8{ "reginald", "-c", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "short string option value" {
    const args = [_][:0]const u8{ "reginald", "-c=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "short string option value merged" {
    const args = [_][:0]const u8{ "reginald", "-c/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "short string option empty quoted value" {
    const args = [_][:0]const u8{ "reginald", "-c=\"\"" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined" {
    const args = [_][:0]const u8{ "reginald", "-vc", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined value" {
    const args = [_][:0]const u8{ "reginald", "-vc=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined value merged" {
    const args = [_][:0]const u8{ "reginald", "-vc/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined value merged quoted" {
    const args = [_][:0]const u8{ "reginald", "-vc\"/tmp/config.toml\"" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined value merged empty quoted" {
    const args = [_][:0]const u8{ "reginald", "-vc\"\"" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqualStrings("", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined no value" {
    const args = [_][:0]const u8{ "reginald", "-vc" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "invalid empty short" {
    const args = [_][:0]const u8{ "reginald", "-" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

// test "subcommand apply" {
//     const args = [_][:0]const u8{ "reginald", "apply" };
//     var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
//     defer parsed.deinit();
//
//     try testing.expect(!parsed.values.contains("config_file"));
//     try testing.expect(!parsed.values.contains("print_version"));
//     try testing.expect(!parsed.values.contains("print_help"));
//     try testing.expect(!parsed.values.contains("quiet"));
//     try testing.expect(!parsed.values.contains("verbose"));
//     try testing.expect(!parsed.values.contains("working_directory"));
//
//     try testing.expectEqual(0, parsed.args.len);
//
//     try testing.expectEqual(Subcommand.apply, parsed.subcommand);
// }
//
// test "subcommand int option" {
//     const args = [_][:0]const u8{ "reginald", "apply", "--jobs", "20" };
//     var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
//     defer parsed.deinit();
//
//     try testing.expect(!parsed.values.contains("config_file"));
//     try testing.expect(!parsed.values.contains("print_version"));
//     try testing.expect(!parsed.values.contains("print_help"));
//     try testing.expect(!parsed.values.contains("quiet"));
//     try testing.expect(!parsed.values.contains("verbose"));
//     try testing.expect(!parsed.values.contains("working_directory"));
//     try testing.expect(parsed.values.contains("max_jobs"));
//
//     try testing.expect(parsed.values.get("max_jobs") != null);
//     try testing.expectEqual(20, parsed.values.get("max_jobs").?.int);
//
//     try testing.expectEqual(0, parsed.args.len);
//
//     try testing.expectEqual(Subcommand.apply, parsed.subcommand);
// }
//
// test "subcommand global option before" {
//     const args = [_][:0]const u8{ "reginald", "--verbose", "apply", "--jobs", "20" };
//     var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
//     defer parsed.deinit();
//
//     try testing.expect(parsed.values.contains("max_jobs"));
//     try testing.expect(parsed.values.contains("verbose"));
//     try testing.expect(!parsed.values.contains("config_file"));
//     try testing.expect(!parsed.values.contains("print_version"));
//     try testing.expect(!parsed.values.contains("print_help"));
//     try testing.expect(!parsed.values.contains("quiet"));
//     try testing.expect(!parsed.values.contains("working_directory"));
//
//     try testing.expect(parsed.values.get("max_jobs") != null);
//     try testing.expect(parsed.values.get("verbose") != null);
//     try testing.expectEqual(20, parsed.values.get("max_jobs").?.int);
//     try testing.expectEqual(true, parsed.values.get("verbose").?.bool);
//
//     try testing.expectEqual(0, parsed.args.len);
//
//     try testing.expectEqual(Subcommand.apply, parsed.subcommand);
// }
//
// test "subcommand global option after" {
//     const args = [_][:0]const u8{ "reginald", "apply", "--verbose", "--jobs", "20" };
//     var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
//     defer parsed.deinit();
//
//     try testing.expect(parsed.values.contains("max_jobs"));
//     try testing.expect(parsed.values.contains("verbose"));
//     try testing.expect(!parsed.values.contains("config_file"));
//     try testing.expect(!parsed.values.contains("print_version"));
//     try testing.expect(!parsed.values.contains("print_help"));
//     try testing.expect(!parsed.values.contains("quiet"));
//     try testing.expect(!parsed.values.contains("working_directory"));
//
//     try testing.expect(parsed.values.get("max_jobs") != null);
//     try testing.expect(parsed.values.get("verbose") != null);
//     try testing.expectEqual(20, parsed.values.get("max_jobs").?.int);
//     try testing.expectEqual(true, parsed.values.get("verbose").?.bool);
//
//     try testing.expectEqual(0, parsed.args.len);
//
//     try testing.expectEqual(Subcommand.apply, parsed.subcommand);
// }
//
// test "subcommand global option both" {
//     const args = [_][:0]const u8{ "reginald", "--quiet", "apply", "--verbose", "--jobs", "20" };
//     var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
//     defer parsed.deinit();
//
//     try testing.expect(parsed.values.contains("max_jobs"));
//     try testing.expect(parsed.values.contains("quiet"));
//     try testing.expect(parsed.values.contains("verbose"));
//     try testing.expect(!parsed.values.contains("config_file"));
//     try testing.expect(!parsed.values.contains("print_version"));
//     try testing.expect(!parsed.values.contains("print_help"));
//     try testing.expect(!parsed.values.contains("working_directory"));
//
//     try testing.expect(parsed.values.get("max_jobs") != null);
//     try testing.expect(parsed.values.get("quiet") != null);
//     try testing.expect(parsed.values.get("verbose") != null);
//     try testing.expectEqual(20, parsed.values.get("max_jobs").?.int);
//     try testing.expectEqual(true, parsed.values.get("quiet").?.bool);
//     try testing.expectEqual(true, parsed.values.get("verbose").?.bool);
//
//     try testing.expectEqual(0, parsed.args.len);
//
//     try testing.expectEqual(Subcommand.apply, parsed.subcommand);
// }
//
// test "subcommand option before" {
//     const args = [_][:0]const u8{ "reginald", "--verbose", "--jobs", "20", "apply" };
//     const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
//     try testing.expectError(error.InvalidArgs, parsed);
// }

// test "no unknown" {
//     const args = [_][:0]const u8{ "reginald", "apply", "--verbose", "--jobs", "40" };
//     var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
//     defer parsed.deinit();
//
//     try testing.expect(parsed.values.contains("max_jobs"));
//     try testing.expect(parsed.values.contains("verbose"));
//     try testing.expect(!parsed.values.contains("config_file"));
//     try testing.expect(!parsed.values.contains("print_version"));
//     try testing.expect(!parsed.values.contains("print_help"));
//     try testing.expect(!parsed.values.contains("quiet"));
//     try testing.expect(!parsed.values.contains("working_directory"));
//
//     try testing.expect(parsed.values.get("max_jobs") != null);
//     try testing.expect(parsed.values.get("verbose") != null);
//     try testing.expectEqual(40, parsed.values.get("max_jobs").?.int);
//     try testing.expectEqual(true, parsed.values.get("verbose").?.bool);
//
//     try testing.expectEqual(0, parsed.args.len);
//
//     try testing.expectEqual(Subcommand.apply, parsed.subcommand);
// }

test "unknown long option" {
    const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(1, parsed.args.len);
    try testing.expectEqualStrings("--not-real", parsed.args[0]);
}

test "unknown short option" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "-ah" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("print_help") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("print_help").?.bool);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(1, parsed.args.len);
    try testing.expectEqualStrings("-a", parsed.args[0]);
}

test "unknown arg" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "-h", "not-real" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("print_help") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("print_help").?.bool);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(1, parsed.args.len);
    try testing.expectEqualStrings("not-real", parsed.args[0]);
}

test "unknown arg and options after" {
    const args = [_][:0]const u8{ "reginald", "--verbose", "-C", "/tmp", "not-real", "-c", "test", "-e", "-h" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(parsed.values.contains("working_directory"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("quiet"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expect(parsed.values.get("print_help") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expect(parsed.values.get("working_directory") != null);
    try testing.expectEqualStrings("test", parsed.values.get("config_file").?.string);
    try testing.expectEqual(true, parsed.values.get("print_help").?.bool);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);
    try testing.expectEqualStrings("/tmp", parsed.values.get("working_directory").?.string);

    try testing.expectEqual(2, parsed.args.len);
    try testing.expectEqualStrings("not-real", parsed.args[0]);
    try testing.expectEqualStrings("-e", parsed.args[1]);
}

test "multiple unknown" {
    const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose", "-ah", "unreal", "-b" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("print_help") != null);
    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("print_help").?.bool);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(4, parsed.args.len);
    try testing.expectEqualStrings("--not-real", parsed.args[0]);
    try testing.expectEqualStrings("-a", parsed.args[1]);
    try testing.expectEqualStrings("unreal", parsed.args[2]);
    try testing.expectEqualStrings("-b", parsed.args[3]);
}
