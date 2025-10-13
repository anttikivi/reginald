//! The parsed command-line arguments and the parser for them.

const Args = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const StringHashMap = std.StringHashMap;
const StructField = std.builtin.Type.StructField;
const testing = std.testing;

const Config = @import("Config.zig");
const filepath = @import("filepath.zig");
const OptionType = Config.OptionType;
const output = @import("output.zig");
const Specs = Config.Specs;
const Value = Config.Value;

allocator: Allocator,

/// The arguments remaining after parsing when unknown arguments don't make
/// the parser return an error.
args: []const []const u8,

// subcommand: Subcommand,

/// Values of the command-line options that were found and parsed
/// successfully. The values are stored by the name of the config option
/// that is read from the metadata.
values: StringHashMap(Value),

var stderr_buffer: [4096]u8 = undefined;

const OnUnknown = enum { fail, skip };

const Parser = struct {
    args: []const []const u8,
    on_unknown: OnUnknown,
    pos: usize,
    arg_pos: usize,
    remaining: ArrayList([]u8),
    specs: *const Specs,
    values: StringHashMap(Value),

    const ShortAction = enum {
        break_cluster,
        continue_cluster,
        continue_outer,
    };

    /// Implementation for parsing arguments.
    fn parse(self: *@This(), target: *Args, gpa: Allocator) !void {
        while (self.pos < self.args.len) : (self.pos += 1) {
            const arg = self.args[self.pos];
            assert(arg.len > 0);

            if (std.mem.startsWith(u8, arg, "--")) {
                if (arg.len == 2) {
                    break;
                }

                try self.parseLong(gpa);

                continue;
            }

            if (arg[0] == '-' and arg.len > 1) {
                self.arg_pos = 1;
                try self.parseShortCluster(gpa);
                continue;
            }

            switch (self.on_unknown) {
                .fail => {
                    return output.fail("unknown argument: \"{s}\"", .{arg});
                },
                .skip => try self.remaining.append(gpa, try gpa.dupe(u8, arg)),
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

        target.* = .{
            .allocator = gpa,
            .args = switch (self.on_unknown) {
                .fail => try gpa.alloc([]u8, 0),
                .skip => try self.remaining.toOwnedSlice(gpa),
            },
            // .subcommand = subcommand,
            .values = self.values,
        };
    }

    /// Parse long argument and return the additional arguments used. The `args`
    /// passed in should contain the command-line arguments remaining after
    /// `arg`.
    fn parseLong(self: *@This(), gpa: Allocator) !void {
        const arg = self.args[self.pos];

        const end = if (std.mem.indexOfScalarPos(u8, arg, 2, '=')) |j| j else arg.len;
        const long = arg[2..end];
        const key = self.specs.long_options.get(long) orelse switch (self.on_unknown) {
            .fail => return output.fail("invalid command-line option \"--{s}\"", .{long}),
            .skip => {
                try self.remaining.append(gpa, try gpa.dupe(u8, arg));
                return;
            },
        };
        const spec = self.specs.get(key).?;

        if (spec.type != .string_slice and self.values.contains(key)) {
            return output.fail("option \"--{s}\" can be specified only once", .{long});
        }

        var raw_value: ?[]const u8 = null;

        if (end != arg.len) {
            raw_value = arg[end + 1 ..];
        } else if (spec.type != .bool) {
            self.pos += 1;

            if (self.args.len <= self.pos) {
                return output.fail("option \"--{s}\" requires a value", .{long});
            }

            raw_value = self.args[self.pos];
        }

        const prev = blk: {
            if (spec.type == .string_slice) {
                if (self.values.get(key)) |s| {
                    break :blk s;
                }
            }

            break :blk null;
        };

        if (prev) |p| {
            assert(@as(OptionType, p) == spec.type);
        }

        const value = parseValue(gpa, spec.type, raw_value, prev) catch |err| switch (err) {
            error.InvalidCharacter, error.InvalidValue => return output.fail(
                "invalid value for option \"--{s}\": \"{?s}\"",
                .{ long, raw_value },
            ),
            error.OutOfMemory => return err,
            error.Overflow => return output.fail(
                "value given for option \"--{s}\" would overflow: \"{?s}\"",
                .{ long, raw_value },
            ),
        };
        assert(@as(OptionType, value) == spec.type);
        try self.values.put(key, value);
    }

    /// Parse a short argument cluster and return the additional arguments used.
    /// The `args` passed in should contain the command-line arguments remaining
    /// after `arg`.
    fn parseShortCluster(self: *@This(), gpa: Allocator) !void {
        assert(self.arg_pos == 1);
        assert(self.args[self.pos][0] == '-');

        var leftover: ArrayList(u8) = .empty;
        defer leftover.deinit(gpa);

        const arg = self.args[self.pos];

        cluster: while (self.arg_pos < arg.len) : (self.arg_pos += 1) {
            switch (try self.parseShort(gpa, &leftover)) {
                .break_cluster => break :cluster,
                .continue_cluster => continue :cluster,
                .continue_outer => return,
            }
        }

        switch (self.on_unknown) {
            .fail => {},
            .skip => if (leftover.items.len > 0) {
                try self.remaining.append(gpa, try leftover.toOwnedSlice(gpa));
            },
        }
    }

    fn parseShort(self: *@This(), gpa: Allocator, leftover: *ArrayList(u8)) !ShortAction {
        const arg = self.args[self.pos];

        assert(arg[0] == '-');

        const c = arg[self.arg_pos];

        // Equal sign is always handled by the value parser and should not come
        // through the loop for known arguments.
        if (c == '=') {
            switch (self.on_unknown) {
                .fail => return output.fail("unexpected value separator in \"{s}\"", .{arg}),
                .skip => if (leftover.items.len > 0) {
                    try leftover.appendSlice(gpa, arg[self.arg_pos..]);
                } else {
                    return output.fail("unexpected value separator in \"{s}\"", .{arg});
                },
            }

            return .break_cluster;
        }

        const option_key = self.specs.short_options[c] orelse switch (self.on_unknown) {
            .fail => {
                return output.fail("unknown command-line option \"-{c}\" in \"{s}\"", .{ c, arg });
            },
            .skip => {
                if (leftover.items.len > 0) {
                    try leftover.append(gpa, c);
                } else {
                    try leftover.appendSlice(gpa, &[_]u8{ '-', c });
                }

                return .continue_cluster;
            },
        };
        const spec = self.specs.get(option_key).?;

        if (spec.type != .string_slice and self.values.contains(option_key)) {
            return output.fail("option \"-{c}\" can be specified only once", .{c});
        }

        var raw_value: ?[]const u8 = null;

        if (arg.len > self.arg_pos + 1 and arg[self.arg_pos + 1] == '=') {
            raw_value = arg[self.arg_pos + 2 ..];
        } else if (spec.type != .bool) {
            if (arg.len > self.arg_pos + 1) {
                raw_value = arg[self.arg_pos + 1 ..];
            } else {
                self.pos += 1;

                if (self.args.len <= self.pos) {
                    return output.fail("option \"-{c}\" requires a value", .{c});
                }

                raw_value = self.args[self.pos];
            }
        }

        const prev = blk: {
            if (spec.type == .string_slice) {
                if (self.values.get(option_key)) |s| {
                    break :blk s;
                }
            }

            break :blk null;
        };

        if (prev) |p| {
            assert(@as(OptionType, p) == spec.type);
        }

        const value = parseValue(gpa, spec.type, raw_value, prev) catch |err| switch (err) {
            error.InvalidCharacter, error.InvalidValue => return output.fail(
                "invalid value for option \"-{c}\": \"{?s}\"",
                .{ c, raw_value },
            ),
            error.OutOfMemory => return err,
            error.Overflow => return output.fail(
                "value given for option \"-{c}\" would overflow: \"{?s}\"",
                .{ c, raw_value },
            ),
        };
        assert(@as(OptionType, value) == spec.type);
        try self.values.put(option_key, value);

        if (raw_value != null) {
            return .continue_outer;
        }

        return .continue_cluster;
    }
};

/// Parse command-line arguments and fail on unknown arguments.
pub fn parse(self: *Args, gpa: Allocator, args: []const []const u8, specs: *const Specs) !void {
    var parser: Parser = .{
        .args = args,
        .on_unknown = .fail,
        .pos = 0,
        .arg_pos = 0,
        .remaining = .empty,
        .specs = specs,
        .values = .init(gpa),
    };
    defer parser.remaining.deinit(gpa);
    errdefer parser.values.deinit();
    return try parser.parse(self, gpa);
}

/// Parse command-line arguments in a lax manner so that unknown arguments
/// are ignored. This should be used for parsing the command-line arguments
/// during the first run when the options and subcommands that the plugins
/// provide are not known.
///
/// The arguments passed in to the function must not contain the the name of
/// the program.
pub fn parseLaxly(
    self: *Args,
    gpa: Allocator,
    args: []const []const u8,
    specs: *const Specs,
) !void {
    var parser: Parser = .{
        .args = args,
        .on_unknown = .skip,
        .pos = 0,
        .arg_pos = 0,
        .remaining = .empty,
        .specs = specs,
        .values = .init(gpa),
    };
    defer parser.remaining.deinit(gpa);
    errdefer parser.values.deinit();
    return try parser.parse(self, gpa);
}

pub fn deinit(self: *Args) void {
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

/// Given a the type of the command-line option and the raw value as a string,
/// this function parses the option and returns the correct `OptionValue`. If
/// the type of the option is a slice, the potential previous slice value should
/// be passed in as `prev` so the function extends that value instead of
/// replacing it.
fn parseValue(gpa: Allocator, option_type: OptionType, raw: ?[]const u8, prev: ?Value) !Value {
    if (prev) |p| {
        assert(@as(OptionType, p) == option_type);
    }

    return switch (option_type) {
        .bool => .{ .bool = if (raw) |s| try Config.parseBool(s) else true },
        .int => .{ .int = try std.fmt.parseInt(i64, raw.?, 0) },
        .string => .{ .string = try gpa.dupe(u8, raw.?) },
        .string_slice => blk: {
            var list: ArrayList([]const u8) = .empty;
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
        .log_level => .{ .log_level = try Config.parseLogLevel(raw.?) },
    };
}

test parse {
    var specs: Specs = undefined;
    try specs.init(testing.allocator);
    defer specs.deinit();

    {
        const args = [_][:0]const u8{"reginald"};
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose", "--", "--quiet" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=true" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--log" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--log=false" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose=false", "--quiet=something" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "--verbose=" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "--quiet", "--quiet" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--log-level", "debug" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--log-level=info" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{
            "reginald",
            "--config",
            "/tmp/config.toml",
            "--directory",
            "/tmp",
        };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--config=/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--config" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "--config", "/tmp/config.toml", "--verbose" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--chdir=/tmp", "--config", "/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--config", "--verbose" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--cfg" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "--config_file" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "-v" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-v=false", "-q=true" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-qv" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-qv=false" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-v=false", "-q=something" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "-v=" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "-c", "/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-c=/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-c/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-vc", "/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-vc=/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-vc/tmp/config.toml" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "-vc" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "-" };
        var parsed: Args = undefined;
        try testing.expectError(error.Reported, parsed.parse(testing.allocator, args[1..], &specs));
    }

    {
        const args = [_][:0]const u8{ "reginald", "--plugin-paths", "/tmp/plugins" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{ "reginald", "--plugin-paths=/tmp/plugins" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{
            "reginald",
            "--plugin-paths",
            "/tmp/plugins" ++ filepath.delimiter_str ++ "/private/plugins" ++ filepath.delimiter_str ++ "~/reginald/plugins",
        };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{
            "reginald",
            "--plugin-paths=/tmp/plugins" ++ filepath.delimiter_str ++ "/private/plugins" ++ filepath.delimiter_str ++ "~/reginald/plugins",
        };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{
            "reginald",
            "--plugin-paths",
            "/tmp/plugins",
            "-P",
            "/private/plugins",
            "--plugin-paths",
            "~/reginald/plugins",
        };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{ "reginald", "-P", "/tmp/plugins" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{ "reginald", "-P=/tmp/plugins" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{ "reginald", "-P/tmp/plugins" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }

    {
        const args = [_][:0]const u8{ "reginald", "-vP/tmp/plugins" };
        var parsed: Args = undefined;
        try parsed.parse(testing.allocator, args[1..], &specs);
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
                std.debug.print("{any}\n", .{expect});
                std.debug.print("\n======== instead found this: =========\n", .{});
                std.debug.print("{any}\n", .{actual});
                std.debug.print("\n======================================\n", .{});
            }

            try testing.expect(found);
        }

        try testing.expectEqual(0, parsed.args.len);
    }
}

test parseLaxly {
    var specs: Specs = undefined;
    try specs.init(testing.allocator);
    defer specs.deinit();

    {
        const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose" };
        var parsed: Args = undefined;
        try parsed.parseLaxly(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose", "-ah" };
        var parsed: Args = undefined;
        try parsed.parseLaxly(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose", "-h", "not-real" };
        var parsed: Args = undefined;
        try parsed.parseLaxly(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--verbose", "-C", "/tmp", "not-real", "-c", "test", "-z", "-h" };
        var parsed: Args = undefined;
        try parsed.parseLaxly(testing.allocator, args[1..], &specs);
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

    {
        const args = [_][:0]const u8{ "reginald", "--not-real", "--verbose", "-ah", "unreal", "-b" };
        var parsed: Args = undefined;
        try parsed.parseLaxly(testing.allocator, args[1..], &specs);
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
}
