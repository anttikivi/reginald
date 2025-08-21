const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const assert = std.debug.assert;
const StringHashMap = std.StringHashMap;
const StructField = std.builtin.Type.StructField;
const testing = std.testing;

const Config = @import("Config.zig");
const filepath = @import("filepath.zig");
const OptionType = Config.OptionType;

var long_option_lookup: StringHashMap([]const u8) = undefined;
var short_option_lookup: [256]?[]const u8 = undefined;

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
    values: StringHashMap(OptionValue),

    pub fn deinit(self: *@This()) void {
        for (self.args) |s| {
            self.allocator.free(s);
        }
        self.allocator.free(self.args);

        var values_iter = self.values.iterator();
        while (values_iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                .string_slice => |strs| {
                    for (strs) |s| {
                        self.allocator.free(s);
                    }
                    self.allocator.free(strs);
                },
                else => {},
            }
        }
        self.values.deinit();
    }
};

const OptionValue = union(OptionType) {
    bool: bool,
    int: i64,
    string: []const u8,
    string_slice: []const []const u8,
    log_level: std.log.Level,
};

const OnUnknown = enum { fail, skip };

/// Build the lookup tables for mapping the command-line names to config option
/// names. The caller owns the memory of the global tables and must call
/// `deinitTables` to free the memory.
pub fn initTables(gpa: Allocator) !void {
    long_option_lookup = .init(gpa);
    short_option_lookup = .{null} ** 256;

    inline for (@typeInfo(Config).@"struct".decls) |decl| {
        comptime if (!std.mem.endsWith(u8, decl.name, "_spec")) {
            continue;
        };

        const spec = @field(Config, decl.name);
        const key = decl.name[0 .. decl.name.len - @as([]const u8, "_spec").len];
        var long_name: []u8 = undefined;
        if (spec.long) |l| {
            long_name = try gpa.dupe(u8, l);
        } else {
            long_name = try gpa.dupe(u8, key);
            std.mem.replaceScalar(u8, long_name, '.', '-');
            std.mem.replaceScalar(u8, long_name, '_', '-');
        }

        try long_option_lookup.put(long_name, key);

        if (spec.short) |c| {
            short_option_lookup[c] = key;
        }
    }
}

pub fn deinitTables() void {
    var key_it = long_option_lookup.keyIterator();
    while (key_it.next()) |key| {
        long_option_lookup.allocator.free(key.*);
    }
    long_option_lookup.deinit();
}

/// Parse command-line arguments and fail on unknown arguments. The writer is
/// used for printing more detailed error messages if the function encounters
/// invalid arguments.
///
/// The arguments passed in to the function must not contain the the name of
/// the program.
pub fn parseArgs(gpa: Allocator, args: []const []const u8, writer: anytype) !Parsed {
    return parseArgsWithOptions(gpa, .fail, args, writer);
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
pub fn parseArgsLaxly(gpa: Allocator, args: []const []const u8, writer: anytype) !Parsed {
    return parseArgsWithOptions(gpa, .skip, args, writer);
}

/// Implementation for parsing arguments.
///
/// TODO: If there are many unknown arguments, there is a lot of duplicating. It
/// might be worth considering if the parser would benefit from reduced
/// allocations.
fn parseArgsWithOptions(gpa: Allocator, comptime on_unknown: OnUnknown, args: []const []const u8, writer: anytype) !Parsed {
    // const subcommand: ?[]const u8 = null;
    var unknown: ArrayListUnmanaged([]const u8) = switch (on_unknown) {
        .fail => undefined,
        .skip => .empty,
    };
    errdefer switch (on_unknown) {
        .fail => {},
        .skip => unknown.deinit(gpa),
    };

    var values: StringHashMap(OptionValue) = .init(gpa);
    errdefer values.deinit();

    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];
        assert(arg.len > 0);

        if (std.mem.startsWith(u8, arg, "--")) {
            if (arg.len == 2) {
                break;
            }

            const option_end = if (std.mem.indexOfScalarPos(u8, arg, 2, '=')) |j| j else arg.len;
            const long = arg[2..option_end];
            const option_key = long_option_lookup.get(long) orelse switch (on_unknown) {
                .fail => {
                    try writer.print("invalid command-line option `--{s}`\n", .{long});
                    return error.InvalidArgs;
                },
                .skip => {
                    try writer.print("invalid command-line option `--{s}`\n", .{long});
                    try unknown.append(gpa, try gpa.dupe(u8, arg));
                    continue;
                },
            };
            const spec = Config.specs.get(option_key).?;

            if (spec.type != .string_slice and values.contains(option_key)) {
                try writer.print("option `--{s}` can be specified only once\n", .{long});
                return error.InvalidArgs;
            }

            var raw_value: ?[]const u8 = null;

            if (option_end != arg.len) {
                raw_value = arg[option_end + 1 ..];
            } else if (spec.type != .bool) {
                if (i + 1 >= args.len) {
                    try writer.print("option `--{s}` requires a value\n", .{long});
                    return error.InvalidArgs;
                }

                i += 1;
                raw_value = args[i];
            }

            const prev = blk: {
                if (spec.type == .string_slice) {
                    if (values.get(option_key)) |s| {
                        break :blk s;
                    }
                }

                break :blk null;
            };

            // TODO: Add more meaningful error message.
            const value = try parseValue(gpa, spec.type, raw_value, prev);
            try values.put(option_key, value);

            continue;
        }

        if (arg[0] == '-' and arg.len > 1) {
            var rest: ?ArrayListUnmanaged(u8) = null;
            defer if (rest) |*list| {
                list.deinit(gpa);
            };

            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const c = arg[j];

                if (c == '=') {
                    switch (on_unknown) {
                        .fail => {
                            try writer.print("unexpected value separator in `{s}`\n", .{arg});
                            return error.InvalidArgs;
                        },
                        .skip => {
                            if (rest) |*list| {
                                try list.appendSlice(gpa, arg[j..]);
                            } else {
                                try writer.print("unexpected value separator in `{s}`\n", .{arg});
                                return error.InvalidArgs;
                            }
                        },
                    }

                    break;
                }

                const option_key = short_option_lookup[c] orelse switch (on_unknown) {
                    .fail => {
                        try writer.print("unknown command-line option `-{c}` in `{s}`\n", .{ c, arg });
                        return error.InvalidArgs;
                    },
                    .skip => {
                        if (rest) |*list| {
                            try list.append(gpa, c);
                        } else {
                            rest = .empty;
                            try rest.?.appendSlice(gpa, &[_]u8{ '-', c });
                        }

                        continue;
                    },
                };
                const spec = Config.specs.get(option_key).?;

                if (spec.type != .string_slice and values.contains(option_key)) {
                    try writer.print("option `-{c}` can be specified only once\n", .{c});
                    return error.InvalidArgs;
                }

                var raw_value: ?[]const u8 = null;

                if (arg.len > j + 1 and arg[j + 1] == '=') {
                    raw_value = arg[j + 2 ..];
                } else if (spec.type != .bool) {
                    if (arg.len > j + 1) {
                        raw_value = arg[j + 1 ..];
                    } else if (i + 1 >= args.len) {
                        try writer.print("option `-{c}` requires a value\n", .{c});
                        return error.InvalidArgs;
                    } else {
                        i += 1;
                        raw_value = args[i];
                    }
                }

                const prev = blk: {
                    if (spec.type == .string_slice) {
                        if (values.get(option_key)) |s| {
                            break :blk s;
                        }
                    }

                    break :blk null;
                };

                // TODO: Add more meaningful error message.
                const value = try parseValue(gpa, spec.type, raw_value, prev);
                try values.put(option_key, value);

                if (raw_value != null) {
                    continue :outer;
                }
            }

            switch (on_unknown) {
                .fail => {},
                .skip => if (rest) |list| {
                    try unknown.append(gpa, try gpa.dupe(u8, list.items));
                },
            }

            continue;
        }

        switch (on_unknown) {
            .fail => {
                try writer.print("unknown argument: {s}\n", .{arg});
                return error.InvalidArgs;
            },
            .skip => try unknown.append(gpa, try gpa.dupe(u8, arg)),
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
        .allocator = gpa,
        .args = switch (on_unknown) {
            .fail => try gpa.alloc([]const u8, 0), // TODO: Stupid?
            .skip => try unknown.toOwnedSlice(gpa),
        },
        // .subcommand = subcommand,
        .values = values,
    };
}

/// Given a the type of the command-line option and the raw value as a string,
/// this function parses the option and returns the correct `OptionValue`. If
/// the type of the option is a slice, the potential previous slice value should
/// be passed in as `prev` so the function extends that value instead of
/// replacing it.
fn parseValue(gpa: Allocator, option_type: OptionType, raw: ?[]const u8, prev: ?OptionValue) !OptionValue {
    return switch (option_type) {
        .bool => .{ .bool = if (raw) |s| Config.parseBool(s) catch {
            return error.InvalidArgs;
        } else true },
        .int => .{ .int = std.fmt.parseInt(i64, raw.?, 0) catch return error.InvalidArgs },
        .string => .{ .string = try gpa.dupe(u8, raw.?) },
        .string_slice => blk: {
            if (prev != null) {
                assert(@as(OptionType, prev.?) == option_type);
            }

            var list: ArrayListUnmanaged([]const u8) = .empty;
            defer list.deinit(gpa);
            defer if (prev) |prev_val| switch (prev_val) {
                .string_slice => |strs| {
                    for (strs) |s| {
                        gpa.free(s);
                    }
                    gpa.free(strs);
                },
                else => unreachable,
            };

            if (prev) |s| {
                try list.appendSlice(gpa, s.string_slice);
            }

            // TODO: Allow using more sensible delimiter than the path delimiter
            // if this needs to support non-path string slices.
            var iter = std.mem.splitScalar(u8, raw.?, std.fs.path.delimiter);
            while (iter.next()) |s| {
                if (s.len > 0) {
                    try list.append(gpa, s);
                }
            }

            const slice = try gpa.alloc([]const u8, list.items.len);
            for (list.items, 0..) |s, i| {
                slice[i] = try gpa.dupe(u8, s);
            }

            break :blk .{ .string_slice = slice };
        },
        .log_level => .{ .log_level = Config.parseLogLevel(raw.?) catch return error.InvalidArgs },
    };
}

test "no options" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{"reginald"};
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expectEqual(0, parsed.args.len);
}

test "stop parsing at `--`" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose", "--", "--quiet" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=true" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("quiet") != null);
    try testing.expect(parsed.values.get("verbose") != null);

    try testing.expectEqual(true, parsed.values.get("quiet").?.bool);
    try testing.expectEqual(false, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option in nested config" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--log" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("logging.enabled") != null);
    try testing.expectEqual(true, parsed.values.get("logging.enabled").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option value in nested config" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--log=false" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("logging.enabled") != null);

    try testing.expectEqual(false, parsed.values.get("logging.enabled").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "bool option invalid value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=something" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "bool option empty value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose=" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "duplicate bool" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--quiet", "--quiet" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "string option" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "string option in nested config" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--log-level", "debug" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("logging.level") != null);
    try testing.expectEqual(std.log.Level.debug, parsed.values.get("logging.level").?.log_level);

    try testing.expectEqual(0, parsed.args.len);
}

test "string option equal sign in nested config" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--log-level=info" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("logging.level") != null);
    try testing.expectEqual(std.log.Level.info, parsed.values.get("logging.level").?.log_level);

    try testing.expectEqual(0, parsed.args.len);
}

test "multiple string options" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

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
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--config=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--config" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "bool and string option" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml", "--verbose" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--chdir=/tmp", "--config", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("working_directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--config", "--verbose" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--cfg" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "invalid long option 2" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--config_file" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "short bool option" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-v" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("verbose") != null);
    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    try testing.expectEqual(0, parsed.args.len);
}

test "short bool option value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=true" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-qv" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-qv=false" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("quiet"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-v=false", "-q=something" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "short bool option empty value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-v=" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "short string option" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-c", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-c=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-c/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("working_directory"));

    try testing.expect(parsed.values.get("config_file") != null);
    try testing.expectEqualStrings("/tmp/config.toml", parsed.values.get("config_file").?.string);

    try testing.expectEqual(0, parsed.args.len);
}

test "short option combined" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-vc", "/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-vc=/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-vc/tmp/config.toml" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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

test "short option combined no value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-vc" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "invalid empty short" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-" };
    const parsed = parseArgs(testing.allocator, args[1..], std.io.null_writer);
    try testing.expectError(error.InvalidArgs, parsed);
}

test "string slice option one value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--plugin-paths", "/tmp/plugins" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{"/tmp/plugins"};
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice equal sign option one value" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--plugin-paths=/tmp/plugins" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{"/tmp/plugins"};
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice option multiple value single arg" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{
        "reginald",
        "--plugin-paths",
        "/tmp/plugins" ++ filepath.delimiter_str ++ "/private/plugins" ++ filepath.delimiter_str ++ "~/reginald/plugins",
    };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{ "/tmp/plugins", "/private/plugins", "~/reginald/plugins" };
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice equal sign option multiple value single arg" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{
        "reginald",
        "--plugin-paths=/tmp/plugins" ++ filepath.delimiter_str ++ "/private/plugins" ++ filepath.delimiter_str ++ "~/reginald/plugins",
    };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{ "/tmp/plugins", "/private/plugins", "~/reginald/plugins" };
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice option multiple value multiple arg" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{
        "reginald",
        "--plugin-paths",
        "/tmp/plugins",
        "-P",
        "/private/plugins",
        "--plugin-paths",
        "~/reginald/plugins",
    };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    // var parsed = try parseArgs(testing.allocator, args[1..], std.io.getStdErr().writer());
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{ "/tmp/plugins", "/private/plugins", "~/reginald/plugins" };
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice option single value short" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-P", "/tmp/plugins" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{"/tmp/plugins"};
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice equal sign option single value short" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-P=/tmp/plugins" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{"/tmp/plugins"};
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice option single value short concat" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-P/tmp/plugins" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));
    try testing.expect(!parsed.values.contains("verbose"));

    try testing.expect(parsed.values.get("plugin_paths") != null);

    const expect = [_][]const u8{"/tmp/plugins"};
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
}

test "string slice option single value short concat multiple short" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "-vP/tmp/plugins" };
    var parsed = try parseArgs(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("plugin_paths"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
    try testing.expect(!parsed.values.contains("print_version"));
    try testing.expect(!parsed.values.contains("print_help"));
    try testing.expect(!parsed.values.contains("quiet"));

    try testing.expect(parsed.values.get("plugin_paths") != null);
    try testing.expect(parsed.values.get("verbose") != null);

    try testing.expectEqual(true, parsed.values.get("verbose").?.bool);

    const expect = [_][]const u8{"/tmp/plugins"};
    const actual = parsed.values.get("plugin_paths").?.string_slice;

    try testing.expectEqual(expect.len, actual.len);

    for (expect) |s| {
        var found = false;
        for (actual) |t| {
            if (std.mem.eql(u8, s, t)) {
                found = true;
            }
        }

        if (!found) {
            std.debug.print("\n====== expected this output: =========\n", .{});
            std.debug.print("{s}\n", .{expect});
            std.debug.print("\n======== instead found this: =========\n", .{});
            std.debug.print("{s}\n", .{actual});
            std.debug.print("\n======================================\n", .{});
        }

        try testing.expect(found);
    }

    try testing.expectEqual(0, parsed.args.len);
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose", "-ah" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose", "-h", "not-real" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--verbose", "-C", "/tmp", "not-real", "-c", "test", "-z", "-h" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("config_file"));
    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(parsed.values.contains("working_directory"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
    try testing.expectEqualStrings("-z", parsed.args[1]);
}

test "multiple unknown" {
    try Config.initTable(testing.allocator);
    defer Config.deinitTable();
    try initTables(testing.allocator);
    defer deinitTables();

    const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose", "-ah", "unreal", "-b" };
    var parsed = try parseArgsLaxly(testing.allocator, args[1..], std.io.null_writer);
    defer parsed.deinit();

    try testing.expect(parsed.values.contains("print_help"));
    try testing.expect(parsed.values.contains("verbose"));
    try testing.expect(!parsed.values.contains("config_file"));
    try testing.expect(!parsed.values.contains("logging.enabled"));
    try testing.expect(!parsed.values.contains("logging.level"));
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
