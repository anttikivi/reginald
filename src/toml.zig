const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;

/// Represents a TOML array value that is normally wrapped in a `Value`.
pub const Array = std.ArrayList(Value);

/// Represents a TOML table value that is normally wrapped in a `Value`.
pub const Table = std.StringArrayHashMap(Value);

/// Represents any TOML value that potentially contains other TOML values.
/// The result for parsing a TOML document is a `Value` that represents the root
/// table of the document.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    bool: bool,
    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,
    array: Array,
    table: Table,

    /// Recursively free memory for this value and all nested values.
    /// The `allocator` must be the same one used in `parse` to create this Value.
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| {
                var i: usize = 0;
                while (i < arr.items.len) : (i += 1) {
                    var item = &arr.items[i];
                    item.deinit(allocator);
                }
                arr.deinit();
            },
            .table => |*t| {
                var it = t.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                t.deinit();
            },
            else => {},
        }
    }
};

/// Rich error information for parse failures
pub const ParseErrorInfo = struct {
    /// The Zig error name, e.g. "UnexpectedToken", "InvalidNumber"
    error_name: []const u8,
    /// A more helpful human-readable message about what went wrong
    message: []const u8,
    /// 1-based line index where the error occurred
    line: usize,
    /// 1-based column (byte offset within the line)
    column: usize,
    /// A slice of the input containing the line where the error happened
    snippet: []const u8,
};

fn computeLineColumnAndSnippet(input: []const u8, cursor: usize) struct { line: usize, column: usize, snippet: []const u8 } {
    var i: usize = 0;
    var line: usize = 1;
    while (i < cursor and i < input.len) : (i += 1) {
        if (input[i] == '\n') line += 1;
    }

    var start: usize = if (cursor > 0) cursor - 1 else 0;
    while (start > 0 and input[start - 1] != '\n') : (start -= 1) {}

    var end: usize = cursor;
    while (end < input.len and input[end] != '\n') : (end += 1) {}

    const col = (cursor - start) + 1;
    return .{ .line = line, .column = col, .snippet = input[start..end] };
}

/// Extended parse that reports diagnostics on failure without throwing away error location.
/// If diag_out is non-null, it will be populated when this function returns an error.
pub fn parseEx(allocator: Allocator, input: []const u8, diag_out: ?*ParseErrorInfo) !Value {
    if (!utf8Validate(input)) {
        if (diag_out) |outp| {
            const pos = computeLineColumnAndSnippet(input, 0);
            outp.* = .{ .error_name = "InvalidUtf8", .message = "input is not valid UTF-8", .line = pos.line, .column = pos.column, .snippet = pos.snippet };
        }
        return error.InvalidUtf8;
    }

    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();
    const scratch = tmp_arena.allocator();

    var parsing_root: Parser.ParsingValue = .{ .value = .{ .table = .init(scratch) } };
    var scanner = Scanner.initCompleteInput(input);
    scanner.last_error_message = null;
    var parser = Parser.init(scratch, &scanner, &parsing_root);

    while (true) {
        var token = scanner.nextKey() catch |e| {
            if (diag_out) |outp| {
                const pos = computeLineColumnAndSnippet(input, scanner.cursor);
                outp.* = .{ .error_name = @errorName(e), .message = scanner.last_error_message orelse defaultErrorMessage(e), .line = pos.line, .column = pos.column, .snippet = pos.snippet };
            }
            return e;
        };
        if (token == .end_of_file) {
            break;
        }

        const step_err: ?anyerror = switch (token) {
            .line_feed => null,
            .left_bracket => blk: {
                parser.parseTableExpression() catch |e| break :blk e;
                break :blk null;
            },
            .double_left_bracket => blk: {
                parser.parseArrayTableExpression() catch |e| break :blk e;
                break :blk null;
            },
            .literal, .string, .literal_string => blk: {
                parser.parseKeyValueExpressionStartingWith(token) catch |e| break :blk e;
                break :blk null;
            },
            else => error.UnexpectedToken,
        };
        if (step_err) |e| {
            if (diag_out) |outp| {
                const pos = computeLineColumnAndSnippet(input, scanner.cursor);
                outp.* = .{ .error_name = @errorName(e), .message = scanner.last_error_message orelse defaultErrorMessage(e), .line = pos.line, .column = pos.column, .snippet = pos.snippet };
            }
            return e;
        }

        token = scanner.nextKey() catch |e| {
            if (diag_out) |outp| {
                const pos = computeLineColumnAndSnippet(input, scanner.cursor);
                outp.* = .{ .error_name = @errorName(e), .message = scanner.last_error_message orelse defaultErrorMessage(e), .line = pos.line, .column = pos.column, .snippet = pos.snippet };
            }
            return e;
        };
        if (token == .line_feed or token == .end_of_file) {
            continue;
        }

        if (diag_out) |outp| {
            const pos = computeLineColumnAndSnippet(input, scanner.cursor);
            outp.* = .{ .error_name = @errorName(error.UnexpectedToken), .message = scanner.last_error_message orelse defaultErrorMessage(error.UnexpectedToken), .line = pos.line, .column = pos.column, .snippet = pos.snippet };
        }
        return error.UnexpectedToken;
    }

    return parseResult(allocator, parsing_root);
}

fn defaultErrorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.UnexpectedToken => "unexpected token",
        error.SyntaxError => "syntax error",
        error.UnexpectedEndOfInput => "unexpected end of input",
        error.InvalidNumber => "invalid number literal",
        error.InvalidDate => "invalid date literal",
        error.InvalidTime => "invalid time literal",
        error.InvalidDatetime => "invalid datetime literal",
        error.DuplicateKey => "duplicate key",
        error.NoTableFound => "invalid dotted key path (no such table)",
        error.NotArrayOfTables => "expected array of tables",
        error.EmptyArray => "array cannot be empty here",
        error.InvalidUtf8 => "input is not valid UTF-8",
        error.InvalidCharacter => "invalid character",
        else => "parse error",
    };
}

const Token = union(enum) {
    dot,
    equal,
    comma,
    left_bracket, // [
    double_left_bracket, // [[
    right_bracket, // ]
    double_right_bracket, // ]]
    left_brace, // {
    right_brace, // }

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    int: i64,
    float: f64,
    bool: bool,

    datetime: Datetime,
    local_datetime: Datetime,
    local_date: Date,
    local_time: Time,

    line_feed,
    end_of_file,
};

/// Represents a TOML datetime value. The value can be either a normal datetime
/// or a local datetime, and the `tz` is set to `null` in local datetimes.
pub const Datetime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,
    tz: ?i16 = null,

    fn isValid(self: @This()) bool {
        // TODO: Can year be zero? Otherwise years need no validation as
        // the integer is unsigned.
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };
        if (self.day == 0 or self.day > days_in_month[self.month - 1]) {
            return false;
        }

        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        if ((self.month == 6 and self.day == 30) or (self.month == 12 and self.day == 31)) {
            if (self.second > 60) {
                return false;
            }
        } else if (self.second > 59) {
            return false;
        }

        // TODO: Should we validate the fractional seconds?

        if (self.tz == null) {
            return true;
        }

        return isValidTimezone(self.tz.?);
    }

    /// Allocates the datetime into a formatted string. The caller owns
    /// the result and must call `free` on it.
    ///
    /// TODO: This is not the standard way of doing this.
    pub fn string(self: *const @This(), allocator: Allocator) ![]const u8 {
        var value: []const u8 = try std.fmt.allocPrint(
            allocator,
            "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );

        if (self.nano) |nano| {
            value = try std.fmt.allocPrint(allocator, "{s}.{d:0>9}", .{ value, nano });
        }

        if (self.tz) |tz| {
            const t: u16 = @abs(tz);

            if (t == 0) {
                return std.fmt.allocPrint(allocator, "{s}Z", .{value});
            }

            const h = t / 60;
            const m = t % 60;
            const sign = if (tz < 0) "-" else "+";

            return std.fmt.allocPrint(allocator, "{s}{s}{d:0>2}:{d:0>2}", .{ value, sign, h, m });
        } else {
            return value;
        }
    }
};

/// Represents a local TOML date value.
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,

    fn isValid(self: @This()) bool {
        // TODO: Can year be zero? Otherwise years need no validation as
        // the integer is unsigned.
        if (self.month == 0 or self.month > 12) {
            return false;
        }

        const is_leap_year = self.year % 4 == 0 and (self.year % 100 != 0 or self.year % 400 == 0);
        const days_in_month = [_]u8{
            31,
            if (is_leap_year) 29 else 28,
            31,
            30,
            31,
            30,
            31,
            31,
            30,
            31,
            30,
            31,
        };
        return self.day > 0 and self.day <= days_in_month[self.month - 1];
    }

    /// Allocates the date into a formatted string. The caller owns the result
    /// and must call `free` on it.
    ///
    /// TODO: This is not the standard way of doing this.
    pub fn string(self: *const @This(), allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{d}-{d:0>2}-{d:0>2}",
            .{ self.year, self.month, self.day },
        );
    }
};

/// Represents a local TOML time value.
pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8,
    nano: ?u32 = null,

    fn isValid(self: @This()) bool {
        if (self.hour > 23) {
            return false;
        }

        if (self.minute > 59) {
            return false;
        }

        return self.second <= 59;
    }

    /// Allocates the time into a formatted string. The caller owns the result
    /// and must call `free` on it.
    ///
    /// TODO: This is not the standard way of doing this.
    pub fn string(self: *const @This(), allocator: Allocator) ![]const u8 {
        const value: []const u8 = try std.fmt.allocPrint(
            allocator,
            "{d:0>2}:{d:0>2}:{d:0>2}",
            .{ self.hour, self.minute, self.second },
        );

        if (self.nano) |nano| {
            return std.fmt.allocPrint(allocator, "{s}.{d:0>9}", .{ value, nano });
        }

        return value;
    }
};

/// The parsing API that emits tokens based on the TOML document input.
///
/// TODO: Consider implementing streaming so that we can parse TOML documents
/// with smaller memory footprint.
const Scanner = struct {
    input: []const u8 = "",
    cursor: usize = 0,
    end: usize = 0,
    line: u64 = 0,
    /// Last error message set by scanning/parsing routines for richer diagnostics
    last_error_message: ?[]const u8 = null,
    /// Internal buffer for formatted error messages
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    /// Constant that marks the end of input when scanning for the next
    /// character.
    const end_of_input: u8 = 0;

    /// Initialize a `Scanner` with the complete TOML document input as a single
    /// slice.
    fn initCompleteInput(input: []const u8) @This() {
        return .{
            .input = input,
            .end = input.len,
        };
    }

    inline fn setErrorMessage(self: *@This(), msg: []const u8) void {
        self.last_error_message = msg;
    }

    inline fn setErrorMessageFmt(self: *@This(), comptime fmt_str: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.err_buf, fmt_str, args) catch {
            self.last_error_message = fmt_str;
            return;
        };
        self.err_len = written.len;
        self.last_error_message = self.err_buf[0..self.err_len];
    }

    fn isValidChar(c: u8) bool {
        return ascii.isPrint(c) or (c & 0x80) != 0;
    }

    /// Check if the next character matches c.
    fn match(self: *const @This(), c: u8) bool {
        if (self.cursor < self.end and self.input[self.cursor] == c) {
            return true;
        }

        if (c == '\n' and self.cursor + 1 < self.end) {
            return self.input[self.cursor] == '\r' and self.input[self.cursor + 1] == '\n';
        }

        return false;
    }

    /// Check if the next character matches any of the characters in s.
    fn matchAny(self: *const @This(), s: []const u8) bool {
        for (s) |c| {
            if (self.match(c)) {
                return true;
            }
        }

        return false;
    }

    /// Check if the next n characters match c.
    fn matchN(self: *const @This(), c: u8, n: comptime_int) bool {
        if (n < 2) {
            @compileError("calling Scanner.matchN with n < 2");
        }

        assert(c != '\n');

        if (self.cursor + n >= self.end) {
            return false;
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.input[self.cursor + i] != c) {
                return false;
            }
        }

        return true;
    }

    /// Check if the next token might be a time.
    fn matchTime(self: *const @This()) bool {
        return self.cursor + 2 < self.end and ascii.isDigit(self.input[self.cursor]) and
            ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':';
    }

    /// Check if the next token might be a date.
    fn matchDate(self: *const @This()) bool {
        return self.cursor + 4 < self.end and ascii.isDigit(self.input[self.cursor]) and
            ascii.isDigit(self.input[self.cursor + 1]) and
            ascii.isDigit(self.input[self.cursor + 2]) and
            ascii.isDigit(self.input[self.cursor + 3]) and
            self.input[self.cursor + 4] == '-';
    }

    /// Check if the next token might be a boolean literal.
    fn matchBool(self: *const @This()) bool {
        return self.cursor < self.end and
            (self.input[self.cursor] == 't' or self.input[self.cursor] == 'f');
    }

    /// Check if the next token might be some number literal.
    fn matchNumber(self: *const @This()) bool {
        if (self.cursor < self.end and
            mem.indexOfScalar(u8, "0123456789+-._", self.input[self.cursor]) != null)
        {
            return true;
        }

        if (self.cursor + 2 < self.end) {
            if (mem.eql(u8, "nan", self.input[self.cursor .. self.cursor + 3]) or
                mem.eql(u8, "inf", self.input[self.cursor .. self.cursor + 3]))
            {
                return true;
            }
        }

        return false;
    }

    /// Get the next character in the input. It returns '\0' when it finds
    /// the end of input regardless of whether the input is null-terminated.
    fn nextChar(self: *@This()) u8 {
        var ret: u8 = end_of_input;

        if (self.cursor < self.end) {
            ret = self.input[self.cursor];
            self.cursor += 1;

            if (ret == '\r' and self.cursor < self.end and self.input[self.cursor] == '\n') {
                ret = self.input[self.cursor];
                self.cursor += 1;
            }
        }

        if (ret == '\n') {
            self.line += 1;
        }

        return ret;
    }

    /// Get the next token from the input.
    fn next(self: *@This(), comptime key_mode: bool) !Token {
        // Limit the loop to the maximum length of the input even though we
        // basically loop until we find a return value.
        while (self.cursor < self.end) {
            var c = self.nextChar();

            switch (c) {
                '\n' => return .line_feed,

                ' ', '\t' => continue, // skip whitespace

                '#' => {
                    while (!self.match('\n')) {
                        c = self.nextChar();
                        if (c == end_of_input and self.cursor >= self.end) {
                            break;
                        }

                        switch (c) {
                            0...8, 0x0a...0x1f, 0x7f => {
                                self.setErrorMessage("invalid control character in comment");
                                return error.InvalidCharacter;
                            },
                            else => {},
                        }
                    }

                    continue; // skip comment
                },

                '.' => return .dot,
                '=' => return .equal,
                ',' => return .comma,

                '[' => {
                    if (key_mode and self.match('[')) {
                        _ = self.nextChar();
                        return .double_left_bracket;
                    }

                    return .left_bracket;
                },

                ']' => {
                    if (key_mode and self.match(']')) {
                        _ = self.nextChar();
                        return .double_right_bracket;
                    }

                    return .right_bracket;
                },

                '{' => return .left_brace,
                '}' => return .right_brace,

                '"' => {
                    // Move back so that `scanString` finds the first quote.
                    self.cursor -= 1;
                    return self.scanString();
                },
                '\'' => {
                    self.cursor -= 1;
                    return self.scanLiteralString();
                },

                else => {
                    // Disallow unprintable control characters outside strings/comments
                    if ((c <= 8) or (c >= 0x0a and c <= 0x1f) or c == 0x7f) {
                        self.setErrorMessage("invalid control character in document");
                        return error.InvalidCharacter;
                    }
                    self.cursor -= 1;
                    return if (key_mode) self.scanLiteral() else self.scanNonstringLiteral();
                },
            }
        }

        // If we're at end-of-input, surface that explicitly to callers.
        return .end_of_file;
    }

    /// Get the next token in the TOML document with the key mode enabled.
    fn nextKey(self: *@This()) !Token {
        return self.next(true);
    }

    /// Get the next token in the TOML document with the key mode disabled.
    fn nextValue(self: *@This()) !Token {
        return self.next(false);
    }

    /// Scan the upcoming multiline string in the TOML document and return
    /// a token matching it.
    ///
    /// TODO: Clear up the allocations.
    fn scanMultilineString(self: *@This()) !Token {
        assert(self.matchN('"', 3));

        // Skip the opening quotes.
        _ = self.nextChar();
        _ = self.nextChar();
        _ = self.nextChar();

        // Trim the first newline after opening the multiline string.
        if (self.match('\n')) {
            _ = self.nextChar();
        }

        const start = self.cursor;

        while (self.cursor < self.end) { // force upper limit to loop
            if (self.matchN('"', 3)) {
                if (self.matchN('"', 4)) {
                    if (self.matchN('"', 6)) {
                        self.setErrorMessage("invalid triple quote sequence in multiline string");
                        return error.UnexpectedToken;
                    }
                } else {
                    break;
                }
            }

            var c = self.nextChar();

            if (c == end_of_input) {
                self.setErrorMessage("unterminated multiline string");
                return error.UnexpectedEndOfInput;
            }

            if (c != '\\') {
                if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
                    self.setErrorMessage("invalid character in multiline string");
                    return error.UnexpectedToken;
                }

                continue;
            }

            c = self.nextChar();
            if (mem.indexOfScalar(u8, "\"\\bfnrt", c) != null) {
                continue; // skip the "normal" escape sequences
            }

            if (c == 'u' or c == 'U') {
                const len: usize = if (c == 'u') 4 else 8;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    if (!ascii.isHex(self.nextChar())) {
                        self.setErrorMessage("invalid unicode escape in string");
                        return error.UnexpectedToken;
                    }
                }
                continue;
            }

            if (c == ' ' or c == '\t') {
                while (c != end_of_input and (c == ' ' or c == '\t')) {
                    c = self.nextChar();
                }

                if (c != '\n') {
                    self.setErrorMessage("backslash line continuation must be followed by newline");
                    return error.UnexpectedToken;
                }
            }

            if (c == '\n') {
                while (self.matchAny(" \t\n")) {
                    _ = self.nextChar();
                }
                continue;
            }

            self.setErrorMessage("invalid escape sequence in multiline string");
            return error.UnexpectedToken;
        }

        // TODO: Need for allocation?
        const result: Token = .{ .multiline_string = self.input[start..self.cursor] };

        if (!self.matchN('"', 3)) {
            self.setErrorMessage("unterminated multiline string");
            return error.UnexpectedEndOfInput;
        }
        _ = self.nextChar();
        _ = self.nextChar();
        _ = self.nextChar();

        return result;
    }

    /// Scan the upcoming regular string in the TOML document and return a token
    /// matching it.
    ///
    /// TODO: Clear up the allocations.
    fn scanString(self: *@This()) !Token {
        assert(self.match('"'));

        if (self.matchN('"', 3)) {
            return self.scanMultilineString();
        }

        _ = self.nextChar(); // skip the opening quote
        const start = self.cursor;

        while (!self.match('"')) {
            var c = self.nextChar();
            if (c == end_of_input) {
                self.setErrorMessage("unterminated string");
                return error.UnexpectedEndOfInput;
            }

            if (c != '\\') {
                if (!(isValidChar(c) or c == ' ' or c == '\t')) {
                    return error.UnexpectedToken;
                }

                continue;
            }

            c = self.nextChar();
            if (mem.indexOfScalar(u8, "\"\\bfnrt", c) != null) {
                continue; // skip the "normal" escape sequences
            }

            if (c == 'u' or c == 'U') {
                const len: usize = if (c == 'u') 4 else 8;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    if (!ascii.isHex(self.nextChar())) {
                        self.setErrorMessage("invalid unicode escape in string");
                        return error.UnexpectedToken;
                    }
                }
                continue;
            }

            self.setErrorMessage("invalid escape sequence in string");
            return error.UnexpectedToken; // bad escape character
        }

        // TODO: Need for allocation?
        const result: Token = .{ .string = self.input[start..self.cursor] };

        assert(self.match('"'));
        _ = self.nextChar();

        return result;
    }

    /// Scan the upcoming multiline literal string in the TOML document and
    /// return a token matching it.
    fn scanMultilineLiteralString(self: *@This()) !Token {
        assert(self.matchN('\'', 3));

        _ = self.nextChar();
        _ = self.nextChar();
        _ = self.nextChar();

        if (self.match('\n')) {
            _ = self.nextChar();
        }

        const start = self.cursor;

        while (self.cursor < self.end) { // force upper limit to loop
            if (self.matchN('\'', 3)) {
                if (self.matchN('\'', 4)) {
                    if (self.matchN('\'', 6)) {
                        return error.UnexpectedToken;
                    }
                } else {
                    break;
                }
            }

            const c = self.nextChar();

            if (c == end_of_input) {
                self.setErrorMessage("unterminated multiline literal string");
                return error.UnexpectedEndOfInput;
            }

            if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
                self.setErrorMessage("invalid character in multiline literal string");
                return error.UnexpectedToken;
            }
        }

        // TODO: Need for allocation?
        const result: Token = .{ .multiline_literal_string = self.input[start..self.cursor] };

        if (!self.matchN('\'', 3)) {
            self.setErrorMessage("unterminated multiline literal string");
            return error.UnexpectedEndOfInput;
        }
        _ = self.nextChar();
        _ = self.nextChar();
        _ = self.nextChar();

        return result;
    }

    /// Scan the upcoming literal string in the TOML document.
    fn scanLiteralString(self: *@This()) !Token {
        assert(self.match('\''));

        if (self.matchN('\'', 3)) {
            return self.scanMultilineLiteralString();
        }

        _ = self.nextChar(); // skip the opening quote
        const start = self.cursor;

        while (!self.match('\'')) {
            const c = self.nextChar();
            if (c == end_of_input) {
                self.setErrorMessage("unterminated literal string");
                return error.UnexpectedEndOfInput;
            }

            if (!(isValidChar(c) or c == '\t')) {
                self.setErrorMessage("invalid character in literal string");
                return error.UnexpectedToken;
            }
        }

        // TODO: Need for allocation?
        const result: Token = .{ .literal_string = self.input[start..self.cursor] };

        assert(self.match('\''));
        _ = self.nextChar();

        return result;
    }

    /// Scan an upcoming literal that is not a string, i.e. a value of some
    /// other type.
    fn scanNonstringLiteral(self: *@This()) !Token {
        if (self.matchTime()) {
            return self.scanTime();
        }

        if (self.matchDate()) {
            return self.scanDatetime();
        }

        if (self.matchBool()) {
            return self.scanBool();
        }

        if (self.matchNumber()) {
            return self.scanNumber();
        }

        self.setErrorMessage("expected a value (number, datetime, or boolean)");
        return error.UnexpectedToken;
    }

    /// Scan an upcoming literal, for example a key.
    fn scanLiteral(self: *@This()) Token {
        const start = self.cursor;
        while (self.cursor < self.end and (ascii.isAlphanumeric(self.input[self.cursor]) or self.input[self.cursor] == '_' or self.input[self.cursor] == '-')) : (self.cursor += 1) {}
        return .{ .literal = self.input[start..self.cursor] };
    }

    /// Read an integer value from the upcoming characters without the sign.
    fn readInt(self: *@This(), comptime T: type) T {
        var val: T = 0;
        while (ascii.isDigit(self.input[self.cursor])) : (self.cursor += 1) {
            val = val * 10 + @as(T, @intCast(self.input[self.cursor] - '0'));
        }
        return val;
    }

    /// Read exactly N digits as an unsigned integer value.
    fn readFixedDigits(self: *@This(), comptime N: usize) !u32 {
        if (self.cursor + N > self.end) return error.UnexpectedEndOfInput;
        var v: u32 = 0;
        var i: usize = 0;
        while (i < N) : (i += 1) {
            const c = self.input[self.cursor + i];
            if (!ascii.isDigit(c)) {
                self.setErrorMessage("expected digit");
                return error.UnexpectedToken;
            }
            v = v * 10 + (c - '0');
        }
        self.cursor += N;
        return v;
    }

    /// Read a time in the HH:MM:SS.fraction format from the upcoming
    /// characters.
    fn readTime(self: *@This()) !Time {
        var ret: Time = .{ .hour = undefined, .minute = undefined, .second = undefined };
        ret.hour = @intCast(try self.readFixedDigits(2));
        if (self.cursor >= self.end or self.input[self.cursor] != ':') {
            self.setErrorMessage("invalid time: expected ':' between hour and minute");
            return error.InvalidTime;
        }

        self.cursor += 1;
        ret.minute = @intCast(try self.readFixedDigits(2));
        if (self.cursor >= self.end or self.input[self.cursor] != ':') {
            self.setErrorMessage("invalid time: expected ':' between minute and second");
            return error.InvalidTime;
        }

        self.cursor += 1;
        ret.second = @intCast(try self.readFixedDigits(2));
        if (ret.hour > 23 or ret.minute > 59 or ret.second > 59) {
            self.setErrorMessage("invalid time value");
            return error.InvalidTime;
        }

        if (self.cursor >= self.end or self.input[self.cursor] != '.') {
            return ret;
        }

        self.cursor += 1;
        ret.nano = 0;
        var i: usize = 0;
        while (self.cursor < self.end and ascii.isDigit(self.input[self.cursor]) and i < 9) : (self.cursor += 1) {
            ret.nano = ret.nano.? * 10 + (self.input[self.cursor] - '0');
            i += 1;
        }

        while (i < 9) : (i += 1) {
            ret.nano = ret.nano.? * 10;
        }

        return ret;
    }

    /// Read a date in the YYYY-MM-DD format from the upcoming characters.
    fn readDate(self: *@This()) !Date {
        // Note: we no longer need to track the absolute start; validations are done by isValid
        var ret: Date = .{ .year = undefined, .month = undefined, .day = undefined };
        ret.year = @intCast(try self.readFixedDigits(4));
        if (self.cursor >= self.end or self.input[self.cursor] != '-') {
            self.setErrorMessage("invalid date: expected '-' after year");
            return error.InvalidDate;
        }

        self.cursor += 1;
        ret.month = @intCast(try self.readFixedDigits(2));
        if (self.cursor >= self.end or self.input[self.cursor] != '-') {
            self.setErrorMessage("invalid date: expected '-' after month");
            return error.InvalidDate;
        }

        self.cursor += 1;
        ret.day = @intCast(try self.readFixedDigits(2));
        // day validity checked via isValid later in scanDatetime when needed

        return ret;
    }

    /// Read a timezone from the next characters.
    fn readTimezone(self: *@This()) !?i16 {
        const c = self.input[self.cursor];
        if (c == 'Z' or c == 'z') {
            self.cursor += 1;
            return 0; // UTC+00:00
        }

        const sign: i16 = switch (c) {
            '+' => 1,
            '-' => -1,
            else => return null,
        };

        self.cursor += 1;
        // track start not needed due to fixed-width parser

        const hour: i16 = @intCast(try self.readFixedDigits(2));
        if (self.cursor >= self.end or self.input[self.cursor] != ':') {
            self.setErrorMessage("invalid timezone offset: expected ':' between hour and minute");
            return error.InvalidDatetime;
        }

        self.cursor += 1;
        const minute: i16 = @intCast(try self.readFixedDigits(2));
        if (hour > 23 or minute > 59) {
            self.setErrorMessage("invalid timezone offset value");
            return error.InvalidDatetime;
        }

        return (hour * 60 + minute) * sign;
    }

    /// Scan upcoming local time value.
    fn scanTime(self: *@This()) !Token {
        const t = try self.readTime();
        if (!t.isValid()) {
            self.setErrorMessage("invalid time literal");
            return error.InvalidTime;
        }

        return .{ .local_time = t };
    }

    /// Scan an upcoming datetime value.
    fn scanDatetime(self: *@This()) !Token {
        if (self.cursor + 2 >= self.end) {
            self.setErrorMessage("unterminated datetime");
            return error.UnexpectedEndOfInput;
        }

        if (ascii.isDigit(self.input[self.cursor]) and
            ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':')
        {
            const t = try self.readTime();
            if (!t.isValid()) {
                self.setErrorMessage("invalid time literal");
                return error.InvalidTime;
            }

            return .{ .local_time = t };
        }

        const date = try self.readDate();
        const c = self.input[self.cursor];
        if (self.cursor + 3 >= self.end or (c != 'T' and c != 't' and c != ' ') or
            !ascii.isDigit(self.input[self.cursor + 1]) or
            !ascii.isDigit(self.input[self.cursor + 2]) or self.input[self.cursor + 3] != ':')
        {
            if (!date.isValid()) {
                self.setErrorMessage("invalid date literal");
                return error.InvalidDate;
            }

            return .{ .local_date = date };
        }

        self.cursor += 1;
        const time = try self.readTime();
        var dt: Datetime = .{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = time.hour,
            .minute = time.minute,
            .second = time.second,
            .nano = time.nano,
        };

        const tz = try self.readTimezone();
        if (tz == null) {
            if (!dt.isValid()) {
                self.setErrorMessage("invalid datetime value");
                return error.InvalidDatetime;
            }

            return .{ .local_datetime = dt };
        }

        dt.tz = tz;
        if (!dt.isValid()) {
            self.setErrorMessage("invalid datetime value");
            return error.InvalidDatetime;
        }

        return .{ .datetime = dt };
    }

    /// Scan a possible upcoming boolean value.
    fn scanBool(self: *@This()) !Token {
        var val: bool = undefined;
        if (self.cursor + 3 < self.end and mem.eql(u8, "true", self.input[self.cursor .. self.cursor + 4])) {
            val = true;
            self.cursor += 4;
        } else if (self.cursor + 4 < self.end and mem.eql(u8, "false", self.input[self.cursor .. self.cursor + 5])) {
            val = false;
            self.cursor += 5;
        } else {
            return error.UnexpectedToken;
        }

        if (self.cursor < self.end and null == mem.indexOfScalar(u8, "# \r\n\t,}]", self.input[self.cursor])) {
            self.setErrorMessage("invalid trailing characters after boolean literal");
            return error.UnexpectedToken;
        }

        return .{ .bool = val };
    }

    /// Scan a possible upcoming number, i.e. integer or float.
    fn scanNumber(self: *@This()) !Token {
        // Non-decimal bases
        if (self.input[self.cursor] == '0' and self.cursor + 1 < self.end) {
            const base: ?u8 = switch (self.input[self.cursor + 1]) {
                'x' => 16,
                'o' => 8,
                'b' => 2,
                else => null,
            };
            if (base) |b| {
                self.cursor += 2;
                const start = self.cursor;
                const allowed: []const u8 = switch (b) {
                    16 => "_0123456789abcdefABCDEF",
                    8 => "_01234567",
                    2 => "_01",
                    else => unreachable,
                };
                const end_idx = mem.indexOfNonePos(u8, self.input, start, allowed) orelse {
                    self.setErrorMessage("invalid digits for base-prefixed integer");
                    return error.UnexpectedToken;
                };
                if (end_idx == start) {
                    self.setErrorMessage("missing digits after base prefix");
                    return error.InvalidNumber;
                }
                // Validate underscores (not first/last, not doubled)
                var prev_underscore = false;
                var i: usize = start;
                while (i < end_idx) : (i += 1) {
                    const c = self.input[i];
                    if (c == '_') {
                        if (prev_underscore or i == start or i + 1 == end_idx) {
                            self.setErrorMessage("invalid underscore placement in number");
                            return error.InvalidNumber;
                        }
                        prev_underscore = true;
                    } else {
                        prev_underscore = false;
                    }
                }
                // Build buffer without underscores
                var buf = std.ArrayList(u8).init(std.heap.page_allocator);
                defer buf.deinit();
                i = start;
                while (i < end_idx) : (i += 1) {
                    const c = self.input[i];
                    if (c != '_') try buf.append(c);
                }
                const n = try std.fmt.parseInt(i64, buf.items, b);
                self.cursor = end_idx;
                return .{ .int = n };
            }
        }

        // Decimal or float
        const start = self.cursor;
        var idx = self.cursor;
        if (self.input[idx] == '+' or self.input[idx] == '-') idx += 1;
        if (idx >= self.end) {
            self.setErrorMessage("unexpected end of input while reading number");
            return error.UnexpectedEndOfInput;
        }
        if (self.input[idx] == 'i' or self.input[idx] == 'n') return self.scanFloat();
        // Find token end
        idx = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse {
            self.setErrorMessage("malformed number literal");
            return error.UnexpectedToken;
        };
        if (idx == start) {
            self.setErrorMessage("missing digits in number");
            return error.InvalidNumber;
        }
        const slice = self.input[start..idx];
        const has_dot = mem.indexOfScalar(u8, slice, '.') != null;
        const has_exp = mem.indexOfAny(u8, slice, "eE") != null;
        if (has_dot or has_exp) {
            return self.scanFloat();
        }
        // Validate underscores and leading zero rule
        var s_off: usize = 0;
        if (slice[0] == '+' or slice[0] == '-') s_off = 1;
        if (slice[s_off] == '0' and slice.len > s_off + 1) {
            self.setErrorMessage("leading zeros are not allowed in integers");
            return error.InvalidNumber;
        }
        var prev_underscore = false;
        var j: usize = s_off;
        while (j < slice.len) : (j += 1) {
            const c = slice[j];
            if (c == '_') {
                if (prev_underscore or j == s_off or j + 1 == slice.len) {
                    self.setErrorMessage("invalid underscore placement in number");
                    return error.InvalidNumber;
                }
                prev_underscore = true;
            } else if (!ascii.isDigit(c)) {
                self.setErrorMessage("invalid character in integer literal");
                return error.InvalidNumber;
            } else {
                prev_underscore = false;
            }
        }
        // Build buffer without underscores
        var buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer buf.deinit();
        j = 0;
        while (j < slice.len) : (j += 1) {
            const c = slice[j];
            if (c != '_') try buf.append(c);
        }
        const n = try std.fmt.parseInt(i64, buf.items, 10);
        self.cursor = idx;
        return .{ .int = n };
    }

    /// Scan a possible upcoming floating-point literal.
    fn scanFloat(self: *@This()) !Token {
        const start = self.cursor;
        if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') self.cursor += 1;

        if (self.cursor + 3 <= self.end and (mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "inf") or mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "nan"))) {
            self.cursor += 3;
        } else {
            self.cursor = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse {
                self.setErrorMessage("malformed float literal");
                return error.UnexpectedToken;
            };
        }

        const slice = self.input[start..self.cursor];
        // Validate underscores not at ends or adjacent to dot or exponent signs
        var prev_char: u8 = 0;
        var i: usize = 0;
        while (i < slice.len) : (i += 1) {
            const c = slice[i];
            if (c == '_') {
                if (i == 0 or i + 1 == slice.len) {
                    self.setErrorMessage("invalid underscore placement in float literal");
                    return error.InvalidNumber;
                }
                const nxt = slice[i + 1];
                if (!ascii.isDigit(prev_char) or !ascii.isDigit(nxt)) {
                    self.setErrorMessage("invalid underscore placement in float literal");
                    return error.InvalidNumber;
                }
            }
            prev_char = c;
        }
        // Build buffer without underscores
        var buf = std.ArrayList(u8).init(std.heap.page_allocator);
        defer buf.deinit();
        i = 0;
        while (i < slice.len) : (i += 1) {
            const c = slice[i];
            if (c != '_') try buf.append(c);
        }
        // Reject leading zero before decimal point (e.g. 03.14) per TOML
        if (buf.items.len >= 2) {
            var sign_idx: usize = 0;
            if (buf.items[0] == '+' or buf.items[0] == '-') sign_idx = 1;
            if (buf.items[sign_idx] == '0' and buf.items.len > sign_idx + 1 and buf.items[sign_idx + 1] == '.') {
                // ok: 0.xxx
            } else if (buf.items[sign_idx] == '0' and buf.items.len > sign_idx + 1 and ascii.isDigit(buf.items[sign_idx + 1])) {
                self.setErrorMessage("leading zeros are not allowed in float literal");
                return error.InvalidNumber;
            }
        }
        // Disallow floats like 1., .1, or exponents with missing mantissa per TOML
        if (mem.indexOfScalar(u8, buf.items, '.') != null) {
            // Must have digits on both sides of '.'
            const dot_idx = mem.indexOfScalar(u8, buf.items, '.').?;
            if (dot_idx == 0 or dot_idx + 1 >= buf.items.len) {
                self.setErrorMessage("decimal point must have digits on both sides");
                return error.InvalidNumber;
            }
            if (!ascii.isDigit(buf.items[dot_idx - 1]) or !ascii.isDigit(buf.items[dot_idx + 1])) {
                self.setErrorMessage("decimal point must have digits on both sides");
                return error.InvalidNumber;
            }
        }
        // Validate exponent placement: must have digits before and after 'e' or 'E' (with optional sign)
        if (mem.indexOfAny(u8, buf.items, "eE")) |e_idx| {
            if (e_idx == 0) {
                self.setErrorMessage("invalid exponent format");
                return error.InvalidNumber;
            }
            if (!ascii.isDigit(buf.items[e_idx - 1]) and buf.items[e_idx - 1] != '.') {
                self.setErrorMessage("invalid exponent format");
                return error.InvalidNumber;
            }
            var after = e_idx + 1;
            if (after < buf.items.len and (buf.items[after] == '+' or buf.items[after] == '-')) after += 1;
            if (after >= buf.items.len or !ascii.isDigit(buf.items[after])) {
                self.setErrorMessage("invalid exponent format");
                return error.InvalidNumber;
            }
        }
        const f = try std.fmt.parseFloat(f64, buf.items);
        return .{ .float = f };
    }

    fn checkNumberStr(self: *@This(), len: usize, base: u8) bool {
        const start = self.cursor;
        const underscore = mem.indexOfScalarPos(u8, self.input, self.cursor, '_');
        if (underscore) |u| {
            var i: usize = u - start;
            while (i < len) : (i += 1) {
                if (self.input[self.cursor + i] != '_') {
                    continue;
                }

                const left: u8 = if (i == 0) 0 else self.input[self.cursor + i - 1];
                const right: u8 = if (self.cursor + i >= self.end) 0 else self.input[self.cursor + i + 1];
                if (!ascii.isDigit(left) and !(base == 16 and ascii.isHex(left))) {
                    return false;
                }

                if (!ascii.isHex(right) and !(base == 16 and ascii.isHex(right))) {
                    return false;
                }
            }
        }

        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (self.input[self.cursor + i] == '.') {
                if (i == 0 or !ascii.isDigit(self.input[self.cursor - 1]) or !ascii.isDigit(self.input[self.cursor + 1])) {
                    return false;
                }
            }
        }

        if (base == 10) {
            i = if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') self.cursor + 1 else self.cursor;
            if (self.input[i] == '0' and ascii.isDigit(self.input[i + 1])) {
                return false;
            }

            if (mem.indexOfScalarPos(u8, self.input, self.cursor, 'e')) |idx| {
                i = if (self.input[idx] == '+' or self.input[idx] == '-') idx + 1 else idx;
                if (self.input[i] == '0' and ascii.isDigit(self.input[i + 1])) {
                    return false;
                }
            } else if (mem.indexOfScalarPos(u8, self.input, self.cursor, 'E')) |idx| {
                i = if (self.input[idx] == '+' or self.input[idx] == '-') idx + 1 else idx;
                if (self.input[i] == '0' and ascii.isDigit(self.input[i + 1])) {
                    return false;
                }
            }
        }

        return true;
    }
};

/// The parsing state.
const Parser = struct {
    allocator: Allocator,
    scanner: *Scanner,
    root_table: *ParsingValue = undefined,
    current_table: *ParsingValue = undefined,

    const ParseError = Allocator.Error || std.fmt.ParseIntError || error{
        Utf8CannotEncodeSurrogateHalf,
        CodepointTooLarge,

        EmptyArray,
        NotArrayOfTables,
        NoTableFound,
        DuplicateKey,

        InvalidDate,
        InvalidDatetime,
        InvalidNumber,
        InvalidTime,
        SyntaxError,
        UnexpectedEndOfInput,
        UnexpectedToken,
    };

    const ValueFlag = packed struct {
        inlined: bool,
        standard: bool,
        explicit: bool,
    };

    const ParsingArray = std.ArrayList(ParsingValue);
    const ParsingTable = std.StringArrayHashMap(ParsingValue);
    const ParsingValue = struct {
        flag: ValueFlag = .{ .inlined = false, .standard = false, .explicit = false },
        value: union(enum) {
            string: []const u8,
            int: i64,
            float: f64,
            bool: bool,
            datetime: Datetime,
            local_datetime: Datetime,
            local_date: Date,
            local_time: Time,
            array: ParsingArray,
            table: ParsingTable,
        },
    };

    fn init(allocator: Allocator, scanner: *Scanner, root: *ParsingValue) @This() {
        return .{
            .allocator = allocator,
            .scanner = scanner,
            .root_table = root,
            .current_table = root,
        };
    }

    /// Add a new array to the given parsing table pointer and return the newly
    /// created value.
    fn addArray(self: *@This(), table: *ParsingTable, key: []const u8) !*ParsingValue {
        if (table.contains(key)) {
            return error.DuplicateKey;
        }

        try table.put(
            try self.allocator.dupe(u8, key),
            .{ .value = .{ .array = .init(self.allocator) } },
        );

        return table.getPtr(key).?;
    }

    /// Add a new table to the given parsing table pointer and return the newly
    /// created value.
    fn addTable(self: *@This(), table: *ParsingTable, key: []const u8) !*ParsingValue {
        if (table.contains(key)) {
            return error.DuplicateKey;
        }

        try table.put(
            try self.allocator.dupe(u8, key),
            .{ .value = .{ .table = .init(self.allocator) } },
        );

        return table.getPtr(key).?;
    }

    /// Add a new value to the given parsing table pointer.
    fn addValue(table: *ParsingTable, value: ParsingValue, key: []const u8) !void {
        if (table.contains(key)) {
            return error.DuplicateKey;
        }

        try table.put(key, value);
    }

    /// Descend to the final table represented by `keys` starting from the root
    /// table. If a table for a key does not exist, it will be created.
    /// The function returns the final table represented by the keys. If
    /// the table in question is parsed from a standard table header,
    /// `is_standard` should be `true`.
    fn descendToTable(self: *@This(), keys: [][]const u8, root: *ParsingValue, is_standard: bool) !*ParsingValue {
        var table = root;

        for (keys) |key| {
            if (table.value.table.getPtr(key)) |value| {
                switch (value.value) {
                    // For tables, just descend further.
                    .table => {
                        table = value;
                        continue;
                    },

                    // For arrays, find the last entry and descend.
                    .array => |*array| {
                        if (array.items.len == 0) {
                            return error.EmptyArray;
                        }
                        const last = &array.items[array.items.len - 1];
                        switch (last.value) {
                            .table => {
                                table = last;
                                continue;
                            },
                            else => return error.NotArrayOfTables,
                        }
                    },

                    else => return error.NoTableFound,
                }
            } else {
                var next_value = try self.addTable(&table.value.table, key);
                next_value.flag.standard = is_standard;
                switch (next_value.value) {
                    .table => table = next_value,
                    else => unreachable,
                }
                continue;
            }
        }

        return table;
    }

    /// Normalize a string values in got from the TOML document, parsing
    /// the escape codes from it. The caller owns the returned string and must
    /// call `free` on it.
    fn normalizeString(self: *@This(), token: Token) ![]const u8 {
        switch (token) {
            .literal, .literal_string, .multiline_literal_string => |s| return s,
            .string, .multiline_string => {}, // continue
            else => unreachable,
        }

        const orig: []const u8 = switch (token) {
            .string, .multiline_string => |s| s,
            else => unreachable,
        };
        if (mem.indexOfScalar(u8, orig, '\\') == null) {
            return orig;
        }

        var dst: std.ArrayList(u8) = .init(self.allocator);
        errdefer dst.deinit();

        var i: usize = 0;
        while (i < orig.len) : (i += 1) {
            if (orig[i] != '\\') {
                try dst.append(orig[i]);
                continue;
            }

            i += 1;
            const c = orig[i];
            switch (c) {
                '"', '\\' => try dst.append(c),
                'b' => try dst.append(8), // \b
                'f' => try dst.append(12), // \f
                't' => try dst.append('\t'),
                'r' => try dst.append('\r'),
                'n' => try dst.append('\n'),
                'u', 'U' => {
                    const len: usize = if (c == 'u') 4 else 8;
                    const start = i + 1;
                    if (start + len > orig.len) return error.UnexpectedEndOfInput;
                    const s = orig[start .. start + len];
                    const codepoint = try std.fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(codepoint, &buf);
                    try dst.appendSlice(buf[0..n]);
                    i += 1 + len - 1; // -1 because loop will i+=1
                },
                ' ', '\t', '\r', '\n' => {
                    // Line-ending backslash: trim all immediately following spaces, tabs, and newlines.
                    var idx = i;
                    var consumed = false;
                    while (idx < orig.len and (orig[idx] == ' ' or orig[idx] == '\t' or orig[idx] == '\r' or orig[idx] == '\n')) : (idx += 1) {
                        consumed = true;
                    }
                    if (!consumed) return error.UnexpectedToken;
                    i = idx - 1; // continue after the whitespace block
                },
                else => try dst.append(c),
            }
        }

        return dst.toOwnedSlice();
    }

    /// Parse a multipart key.
    fn parseKey(self: *@This()) ![][]const u8 {
        const key_token = try self.scanner.nextKey();
        switch (key_token) {
            .literal, .string, .literal_string => {},
            else => return error.UnexpectedToken,
        }

        var key_parts: std.ArrayList([]const u8) = .init(self.allocator);
        errdefer key_parts.deinit();

        try key_parts.append(try self.normalizeString(key_token));

        while (true) {
            const old_cursor = self.scanner.cursor;
            const old_line = self.scanner.line;

            // If the next part is a dot, eat it.
            const dot = try self.scanner.nextKey();

            if (dot != .dot) {
                self.scanner.cursor = old_cursor;
                self.scanner.line = old_line;
                break;
            }

            const next_token = try self.scanner.nextKey();
            switch (next_token) {
                .literal, .string, .literal_string, .multiline_string => {}, // continue
                else => return error.UnexpectedToken,
            }

            try key_parts.append(try self.normalizeString(next_token));
        }

        return key_parts.toOwnedSlice();
    }

    /// Parse a multipart key when the first token has already been read by the caller.
    fn parseKeyStartingWith(self: *@This(), first: Token) ![][]const u8 {
        switch (first) {
            .literal, .string, .literal_string => {},
            else => return error.UnexpectedToken,
        }

        var key_parts: std.ArrayList([]const u8) = .init(self.allocator);
        errdefer key_parts.deinit();

        try key_parts.append(try self.normalizeString(first));

        while (true) {
            const old_cursor = self.scanner.cursor;
            const old_line = self.scanner.line;

            const dot = try self.scanner.nextKey();
            if (dot != .dot) {
                self.scanner.cursor = old_cursor;
                self.scanner.line = old_line;
                break;
            }

            const next_token = try self.scanner.nextKey();
            switch (next_token) {
                .literal, .string, .literal_string, .multiline_string => {},
                else => return error.UnexpectedToken,
            }

            try key_parts.append(try self.normalizeString(next_token));
        }

        return key_parts.toOwnedSlice();
    }

    fn parseValue(self: *@This(), token: Token) ParseError!ParsingValue {
        switch (token) {
            .string, .multiline_string, .literal_string, .multiline_literal_string => {
                const ret = try self.normalizeString(token);
                return .{ .value = .{ .string = ret } };
            },
            .int => |n| return .{ .value = .{ .int = n } },
            .float => |f| return .{ .value = .{ .float = f } },
            .bool => |b| return .{ .value = .{ .bool = b } },
            .datetime => |dt| return .{ .value = .{ .datetime = dt } },
            .local_datetime => |dt| return .{ .value = .{ .local_datetime = dt } },
            .local_date => |d| return .{ .value = .{ .local_date = d } },
            .local_time => |t| return .{ .value = .{ .local_time = t } },
            .left_bracket => return self.parseInlineArray(),
            .left_brace => return self.parseInlineTable(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseInlineArray(self: *@This()) !ParsingValue {
        var arr: ParsingArray = .init(self.allocator);
        errdefer arr.deinit();

        var need_comma = false;

        // TODO: Add a limit.
        while (true) {
            var token = try self.scanner.nextValue();
            while (token == .line_feed) {
                token = try self.scanner.nextValue();
            }

            if (token == .right_bracket) {
                break;
            }

            if (token == .comma) {
                if (need_comma) {
                    need_comma = false;
                    continue;
                }
                return error.SyntaxError;
            }

            if (need_comma) {
                return error.SyntaxError;
            }

            try arr.append(try self.parseValue(token));
            need_comma = true;
        }

        var ret: ParsingValue = .{ .value = .{ .array = arr } };
        setFlagRecursively(&ret, .{ .inlined = true, .standard = false, .explicit = false });
        return ret;
    }

    fn parseInlineTable(self: *@This()) ParseError!ParsingValue {
        var ret: ParsingValue = .{ .value = .{ .table = .init(self.allocator) } };
        var need_comma = false;
        var was_comma = false;

        // TODO: Add a limit.
        while (true) {
            var token = try self.scanner.nextKey();
            if (token == .right_brace) {
                if (was_comma) {
                    // Trailing comma before closing brace is invalid
                    self.scanner.setErrorMessage("trailing comma before '}' in inline table");
                    return error.UnexpectedToken;
                }
                // Allow closing immediately after a key-value without requiring a comma
                break;
            }

            if (token == .comma) {
                if (need_comma) {
                    need_comma = false;
                    was_comma = true;
                    continue;
                }
                self.scanner.setErrorMessage("unexpected ',' in inline table");
                return error.UnexpectedToken;
            }

            if (need_comma) {
                self.scanner.setErrorMessage("missing ',' between inline table entries");
                return error.UnexpectedToken;
            }

            if (token == .line_feed) {
                self.scanner.setErrorMessage("newline not allowed inside inline table");
                return error.UnexpectedToken;
            }

            const keys = try self.parseKeyStartingWith(token);
            var current_table = try self.descendToTable(keys[0 .. keys.len - 1], &ret, false);
            if (current_table.flag.inlined) {
                // Cannot extend inline table.
                self.scanner.setErrorMessage("cannot extend inline table");
                return error.UnexpectedToken;
            }

            current_table.flag.explicit = true;

            token = try self.scanner.nextValue();
            if (token != .equal) {
                if (token == .line_feed) {
                    // Unexpected newline.
                    self.scanner.setErrorMessage("newline not allowed after key in inline table (expected '=')");
                    return error.UnexpectedToken;
                }

                // Missing `=`.
                self.scanner.setErrorMessage("expected '=' after key in inline table");
                return error.UnexpectedToken;
            }

            token = try self.scanner.nextValue();
            const parsed_val = try self.parseValue(token);
            try switch (current_table.value) {
                .table => |*t| addValue(
                    t,
                    parsed_val,
                    try self.allocator.dupe(u8, keys[keys.len - 1]),
                ),
                else => return error.UnexpectedToken,
            };

            need_comma = true;
            was_comma = false;
        }

        setFlagRecursively(&ret, .{ .inlined = true, .standard = false, .explicit = false });
        return ret;
    }

    /// Parse standard table header expression and set the new table as
    /// the current table in the parser.
    fn parseTableExpression(self: *@This()) !void {
        const keys = try self.parseKey();

        const next_token = try self.scanner.nextKey();
        if (next_token != .right_bracket) {
            self.scanner.setErrorMessage("expected closing ']' for table header");
            return error.UnexpectedToken;
        }

        const last_key = keys[keys.len - 1];
        var table = try self.descendToTable(keys[0 .. keys.len - 1], self.root_table, true);

        if (table.value.table.getPtr(last_key)) |value| {
            // Disallow redefining an inline table or array as a standard table
            switch (value.value) {
                .array => {
                    self.scanner.setErrorMessage("cannot redefine array as table");
                    return error.UnexpectedToken;
                },
                .table => {},
                else => {
                    self.scanner.setErrorMessage("cannot redefine value as table");
                    return error.UnexpectedToken;
                },
            }

            table = value;
            if (table.flag.explicit or table.flag.inlined or !table.flag.standard) {
                // Table cannot be defined more than once and inline tables cannot be extended.
                self.scanner.setErrorMessage("table cannot be defined more than once");
                return error.UnexpectedToken;
            }
        } else {
            // Add the missing table.
            if (table.flag.inlined) {
                // Inline table may not be extended.
                self.scanner.setErrorMessage("cannot extend inline table");
                return error.UnexpectedToken;
            }

            var next_value = try self.addTable(&table.value.table, last_key);
            next_value.flag.standard = true;
            switch (next_value.value) {
                .table => table = next_value,
                else => unreachable,
            }
        }

        table.flag.explicit = true;
        self.current_table = table;
    }

    /// Parse array table header expression and set the new table as the current
    /// table in the parser.
    fn parseArrayTableExpression(self: *@This()) !void {
        const keys = try self.parseKey();

        const next_token = try self.scanner.nextKey();
        if (next_token != .double_right_bracket) {
            self.scanner.setErrorMessage("expected closing ']]' for array of tables header");
            return error.UnexpectedToken;
        }

        const last_key = keys[keys.len - 1];
        var current_value = self.root_table;

        for (keys[0 .. keys.len - 1]) |key| {
            if (current_value.value.table.getPtr(key)) |value| {
                switch (value.value) {
                    // For tables, just descend further.
                    .table => {
                        current_value = value;
                        continue;
                    },

                    // For arrays, find the last entry and descend.
                    .array => |*array| {
                        if (value.flag.inlined) {
                            // Cannot expand array.
                            self.scanner.setErrorMessage("cannot extend inline array");
                            return error.UnexpectedToken;
                        }

                        if (array.items.len == 0) {
                            return error.EmptyArray;
                        }

                        const last = &array.items[array.items.len - 1];
                        switch (last.value) {
                            .table => {
                                current_value = last;
                                continue;
                            },
                            else => return error.NotArrayOfTables,
                        }
                    },

                    else => return error.NoTableFound,
                }
            } else {
                var next_value = try self.addTable(&current_value.value.table, key);
                next_value.flag.standard = true;
                switch (next_value.value) {
                    .table => current_value = next_value,
                    else => unreachable,
                }
                continue;
            }
        }

        if (current_value.value.table.getPtr(last_key)) |value| {
            current_value = value;
        } else {
            // Add the missing array.
            current_value = try self.addArray(&current_value.value.table, last_key);
            assert(mem.eql(u8, @tagName(current_value.value), "array"));
        }

        switch (current_value.value) {
            .array => {}, // continue
            else => return error.UnexpectedToken,
        }

        if (current_value.flag.inlined) {
            // Cannot extend inline array.
            self.scanner.setErrorMessage("cannot extend inline array");
            return error.UnexpectedToken;
        }

        try current_value.value.array.append(.{ .value = .{ .table = .init(self.allocator) } });
        // TODO: This will most probably cause a problem.
        self.current_table = &current_value.value.array.items[current_value.value.array.items.len - 1];
    }

    /// Parse a key-value expression and set the value to the current table.
    fn parseKeyValueExpression(self: *@This()) !void {
        const keys = try self.parseKey();
        var token = try self.scanner.nextKey();
        if (token != .equal) {
            self.scanner.setErrorMessage("expected '=' after key");
            return error.UnexpectedToken;
        }

        token = try self.scanner.nextValue();
        const value = try self.parseValue(token);
        var table = self.current_table;
        for (keys[0 .. keys.len - 1], 0..) |key, i| {
            if (table.value.table.getPtr(key)) |v| {
                switch (v.value) {
                    // For tables, just descend further.
                    .table => {
                        table = v;
                        continue;
                    },
                    .array => return error.NotArrayOfTables,
                    else => return error.NoTableFound,
                }
            } else {
                if (i > 0 and table.flag.explicit) {
                    // Cannot extend a previously defined table using dotted expression.
                    self.scanner.setErrorMessage("cannot extend previously defined table using dotted key");
                    return error.UnexpectedToken;
                }
                table = try self.addTable(&table.value.table, key);
                switch (table.value) {
                    .table => continue,
                    else => unreachable,
                }
            }
        }

        if (table.flag.inlined) {
            // Inline table cannot be extended.
            self.scanner.setErrorMessage("cannot extend inline table");
            return error.UnexpectedToken;
        }

        if (keys.len > 1 and table.flag.explicit) {
            // Cannot extend a previously defined table using dotted expression.
            self.scanner.setErrorMessage("cannot extend previously defined table using dotted key");
            return error.UnexpectedToken;
        }

        try addValue(&table.value.table, value, keys[keys.len - 1]);
    }

    /// Parse a key-value expression where the first key token has already been read.
    fn parseKeyValueExpressionStartingWith(self: *@This(), first: Token) !void {
        const keys = try self.parseKeyStartingWith(first);
        var token = try self.scanner.nextKey();
        if (token != .equal) {
            self.scanner.setErrorMessage("expected '=' after key");
            return error.UnexpectedToken;
        }

        token = try self.scanner.nextValue();
        const value = try self.parseValue(token);
        var table = self.current_table;
        for (keys[0 .. keys.len - 1], 0..) |key, i| {
            if (table.value.table.getPtr(key)) |v| {
                switch (v.value) {
                    .table => {
                        table = v;
                        continue;
                    },
                    .array => return error.NotArrayOfTables,
                    else => return error.NoTableFound,
                }
            } else {
                if (i > 0 and table.flag.explicit) {
                    self.scanner.setErrorMessage("cannot extend previously defined table using dotted key");
                    return error.UnexpectedToken;
                }
                table = try self.addTable(&table.value.table, key);
                switch (table.value) {
                    .table => continue,
                    else => unreachable,
                }
            }
        }

        if (table.flag.inlined) {
            self.scanner.setErrorMessage("cannot extend inline table");
            return error.UnexpectedToken;
        }

        if (keys.len > 1 and table.flag.explicit) {
            self.scanner.setErrorMessage("cannot extend previously defined table using dotted key");
            return error.UnexpectedToken;
        }

        try addValue(&table.value.table, value, keys[keys.len - 1]);
    }

    fn setFlagRecursively(value: *ParsingValue, flag: ValueFlag) void {
        if (flag.inlined) {
            value.flag.inlined = true;
        }

        if (flag.standard) {
            value.flag.standard = true;
        }

        if (flag.explicit) {
            value.flag.explicit = true;
        }

        switch (value.value) {
            .array => |*arr| for (arr.items) |*item| {
                setFlagRecursively(item, flag);
            },
            .table => |*table| for (table.values()) |*item| {
                setFlagRecursively(item, flag);
            },
            else => {},
        }
    }
};

pub fn parse(allocator: Allocator, input: []const u8) !Value {
    // TODO: Maybe add an option to skip the UTF-8 validation for faster
    // parsing.
    if (!utf8Validate(input)) {
        return error.InvalidUtf8;
    }

    // Use a temporary arena for all intermediate parsing allocations.
    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();
    const scratch = tmp_arena.allocator();

    var parsing_root: Parser.ParsingValue = .{ .value = .{ .table = .init(scratch) } };
    var scanner = Scanner.initCompleteInput(input);
    var parser = Parser.init(scratch, &scanner, &parsing_root);

    // Set an upper limit for the loop for safety. There cannot be more tokens
    // than there are characters in the input. If the input is streamed, this
    // needs changing.
    while (true) {
        var token = try scanner.nextKey();
        if (token == .end_of_file) {
            break;
        }

        switch (token) {
            .line_feed => continue,
            .left_bracket => try parser.parseTableExpression(),
            .double_left_bracket => try parser.parseArrayTableExpression(),
            .end_of_file => unreachable,
            .literal, .string, .literal_string => try parser.parseKeyValueExpressionStartingWith(token),
            else => return error.UnexpectedToken,
        }

        token = try scanner.nextKey();
        if (token == .line_feed or token == .end_of_file) {
            continue;
        }

        return error.UnexpectedToken;
    }

    return parseResult(allocator, parsing_root);
}

/// Convert the intermediate parsing values into the proper TOML return values.
fn parseResult(allocator: Allocator, parsed_value: Parser.ParsingValue) !Value {
    switch (parsed_value.value) {
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .int => |n| return .{ .int = n },
        .float => |f| return .{ .float = f },
        .bool => |b| return .{ .bool = b },
        .datetime => |dt| return .{ .datetime = dt },
        .local_datetime => |dt| return .{ .local_datetime = dt },
        .local_date => |d| return .{ .local_date = d },
        .local_time => |t| return .{ .local_time = t },
        .array => |arr| {
            var val: Value = .{ .array = .init(allocator) };
            for (arr.items) |item| {
                try val.array.append(try parseResult(allocator, item));
            }
            return val;
        },
        .table => |t| {
            var val: Value = .{ .table = .init(allocator) };
            var it = t.iterator();
            while (it.next()) |entry| {
                try val.table.put(
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try parseResult(allocator, entry.value_ptr.*),
                );
            }
            return val;
        },
    }
}

/// Check whether the minutes given as `tz` is a valid time zone.
fn isValidTimezone(tz: i16) bool {
    const t: u16 = @abs(tz);
    const h = t / 60;
    const m = t % 60;

    if (h > 23) {
        return false;
    }

    return m < 60;
}

/// Check if the input is a valid UTF-8 string. The function goes through
/// the whole input and checks each byte. It may be skipped if working under
/// strict constraints.
///
/// See: http://unicode.org/mail-arch/unicode-ml/y2003-m02/att-0467/01-The_Algorithm_to_Valide_an_UTF-8_String
fn utf8Validate(input: []const u8) bool {
    const Utf8State = enum { start, a, b, c, d, e, f, g };

    var line: usize = 1; // TODO: We need to print actual information and the line number if the string is not UTF-8.
    var state: Utf8State = .start;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];

        if (c == '\n') {
            line += 1;
        }

        switch (state) {
            .start => switch (c) {
                0...0x7F => {},
                0xC2...0xDF => state = .a,
                0xE1...0xEC, 0xEE...0xEF => state = .b,
                0xE0 => state = .c,
                0xED => state = .d,
                0xF1...0xF3 => state = .e,
                0xF0 => state = .f,
                0xF4 => state = .g,
                0x80...0xBF, 0xC0...0xC1, 0xF5...0xFF => return false,
            },
            .a => switch (c) {
                0x80...0xBF => state = .start,
                else => return false,
            },
            .b => switch (c) {
                0x80...0xBF => state = .a,
                else => return false,
            },
            .c => switch (c) {
                0xA0...0xBF => state = .a,
                else => return false,
            },
            .d => switch (c) {
                0x80...0x9F => state = .a,
                else => return false,
            },
            .e => switch (c) {
                0x80...0xBF => state = .b,
                else => return false,
            },
            .f => switch (c) {
                0x90...0xBF => state = .b,
                else => return false,
            },
            .g => switch (c) {
                0x80...0x8F => state = .b,
                else => return false,
            },
        }
    }

    return true;
}

test "parse basic scalars" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "a = 1\n" ++
        "b = \"hello\"\n" ++
        "c = true\n" ++
        "d = 0x10\n" ++
        "e = 1.5\n";

    var root = try parse(alloc, input);
    defer root.deinit(alloc);

    // Access via switch for clarity
    switch (root) {
        .table => |t| {
            try testing.expect(t.contains("a"));
            try testing.expect(t.contains("b"));
            try testing.expect(t.contains("c"));
            try testing.expect(t.contains("d"));
            try testing.expect(t.contains("e"));

            try testing.expectEqual(@as(i64, 1), t.get("a").?.int);
            try testing.expectEqualStrings("hello", t.get("b").?.string);
            try testing.expectEqual(true, t.get("c").?.bool);
            try testing.expectEqual(@as(i64, 16), t.get("d").?.int);
            try testing.expectApproxEqAbs(@as(f64, 1.5), t.get("e").?.float, 1e-12);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse arrays and inline tables" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "arr = [1, 2, 3]\n" ++
        "obj = { x = \"y\", n = 2 }\n";

    var root = try parse(alloc, input);
    defer root.deinit(alloc);

    switch (root) {
        .table => |t| {
            const arr = t.get("arr").?.array;
            try testing.expectEqual(@as(usize, 3), arr.items.len);
            try testing.expectEqual(@as(i64, 1), arr.items[0].int);
            try testing.expectEqual(@as(i64, 2), arr.items[1].int);
            try testing.expectEqual(@as(i64, 3), arr.items[2].int);

            const obj = t.get("obj").?.table;
            try testing.expectEqualStrings("y", obj.get("x").?.string);
            try testing.expectEqual(@as(i64, 2), obj.get("n").?.int);
        },
        else => return error.TestExpectedEqual,
    }
}

test "parse datetimes and local types" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const input = "dt = 1985-06-18T17:04:07Z\n" ++
        "ld = 1985-06-18\n" ++
        "lt = 17:04:07\n";

    var root = try parse(alloc, input);
    defer root.deinit(alloc);

    switch (root) {
        .table => |t| {
            const dt = t.get("dt").?.datetime;
            try testing.expectEqual(@as(u16, 1985), dt.year);
            try testing.expectEqual(@as(u8, 6), dt.month);
            try testing.expectEqual(@as(u8, 18), dt.day);
            try testing.expectEqual(@as(i16, 0), dt.tz.?);

            const ld = t.get("ld").?.local_date;
            try testing.expectEqual(@as(u16, 1985), ld.year);
            try testing.expectEqual(@as(u8, 6), ld.month);
            try testing.expectEqual(@as(u8, 18), ld.day);

            const lt = t.get("lt").?.local_time;
            try testing.expectEqual(@as(u8, 17), lt.hour);
            try testing.expectEqual(@as(u8, 4), lt.minute);
            try testing.expectEqual(@as(u8, 7), lt.second);
        },
        else => return error.TestExpectedEqual,
    }
}

test "invalid: float leading zero and duplicate inline key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // leading zero float
    try testing.expectError(error.InvalidNumber, parse(alloc, "x = 03.14\n"));

    // duplicate key in inline table
    try testing.expectError(error.DuplicateKey, parse(alloc, "a = { b = 1, b = 2 }\n"));
}
