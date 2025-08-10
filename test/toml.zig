const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const json = std.json;
const mem = std.mem;
const process = std.process;

const toml = @import("toml");

const native_os = builtin.target.os.tag;

const DatetimeType = enum { datetime, datetime_local, date_local, time_local };

const Error = Allocator.Error || fmt.BufPrintError || error{ InvalidDatetime, InvalidTomlValue };

pub fn main() !void {
    var arena = heap.ArenaAllocator.init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const stdin = io.getStdIn().reader();
    const toml_bytes = try stdin.readAllAlloc(allocator, 1024 * 1024); // Adjust size as needed
    defer allocator.free(toml_bytes);

    var parsed = toml.parse(allocator, toml_bytes) catch |e| {
        var diag: toml.ParseErrorInfo = undefined;
        _ = toml.parseEx(allocator, toml_bytes, &diag) catch {};
        if (diag.message.len > 0) {
            std.debug.print("error: {s}: {s} at {d}:{d}\n{s}\n", .{ diag.error_name, diag.message, diag.line, diag.column, diag.snippet });
        } else {
            std.debug.print("error: {s} at {d}:{d}\n{s}\n", .{ diag.error_name, diag.line, diag.column, diag.snippet });
        }
        return e;
    };
    defer parsed.deinit(allocator);
    // const parsed = toml.parse(allocator, toml_bytes) catch {
    //     process.exit(1);
    // };

    const json_value = try createJsonValue(allocator, parsed);
    try json.stringify(json_value, .{}, io.getStdOut().writer());
}

fn createJsonValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    var obj_map = json.ObjectMap.init(allocator);
    var toml_table: toml.Table = undefined;

    switch (toml_value) {
        .table => |t| toml_table = t,
        else => return error.InvalidTomlValue,
    }

    for (toml_table.keys()) |key| {
        const val = toml_table.get(key) orelse return error.InvalidTomlValue;
        try obj_map.put(try allocator.dupe(u8, key), try objectFromValue(allocator, val));
    }

    return .{ .object = obj_map };
}

fn objectFromValue(allocator: Allocator, toml_value: toml.Value) Error!json.Value {
    switch (toml_value) {
        .string => |s| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "string" });
            try obj.put("value", json.Value{ .string = try allocator.dupe(u8, s) });
            return .{ .object = obj };
        },
        .int => |i| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "integer" });
            const s = try fmt.allocPrint(allocator, "{d}", .{i});
            try obj.put("value", json.Value{ .string = s });
            return .{ .object = obj };
        },
        .float => |f| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "float" });
            const s = try fmt.allocPrint(allocator, "{d}", .{f});
            try obj.put("value", json.Value{ .string = s });
            return .{ .object = obj };
        },
        .bool => |b| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "bool" });
            try obj.put("value", json.Value{ .string = if (b) "true" else "false" });
            return .{ .object = obj };
        },
        .datetime => |dt| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "datetime" });
            try obj.put("value", json.Value{ .string = try dt.string(allocator) });
            return .{ .object = obj };
        },
        .local_datetime => |dt| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "datetime-local" });
            try obj.put("value", json.Value{ .string = try dt.string(allocator) });
            return .{ .object = obj };
        },
        .local_date => |d| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "date-local" });
            try obj.put("value", json.Value{ .string = try d.string(allocator) });
            return .{ .object = obj };
        },
        .local_time => |t| {
            var obj = json.ObjectMap.init(allocator);
            try obj.put("type", json.Value{ .string = "time-local" });
            try obj.put("value", json.Value{ .string = try t.string(allocator) });
            return .{ .object = obj };
        },
        .array => |arr| {
            var array = json.Array.init(allocator);
            for (arr.items) |item| {
                const json_value = try objectFromValue(allocator, item);
                try array.append(json_value);
            }
            return .{ .array = array };
        },
        .table => {
            return try createJsonValue(allocator, toml_value);
        },
    }
}
