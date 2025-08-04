const std = @import("std");
const Allocator = std.mem.Allocator;
const ascii = std.ascii;
const assert = std.debug.assert;
const mem = std.mem;

/// Represents a TOML table value that is normally wrapped in a `Value`.
const Table = std.StringArrayHashMap(Value);

/// Represents any TOML value that potentially contains other TOML values.
/// The result for parsing a TOML document is a `Value` that represents the root
/// table of the document.
const Value = union(enum) {
    table: Table,
};

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
const Datetime = struct {
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
        const days_in_month = []u8{
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
};

/// Represents a local TOML date value.
const Date = struct {
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
        const days_in_month = []u8{
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
};

/// Represents a local TOML time value.
const Time = struct {
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

    fn isValidChar(c: u8) bool {
        return ascii.isPrint(c) or (c & 0x80);
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
            mem.indexOfScalar(u8, "0123456789+-._", self.input[self.cursor]))
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
            if (c == end_of_input) {
                return .end_of_file;
            }

            switch (c) {
                '\n' => return .line_feed,

                ' ', '\t' => continue, // skip whitespace

                '#' => {
                    while (!self.match('\n')) {
                        c = self.nextChar();
                        if (c == end_of_input) {
                            break;
                        }

                        switch (c) {
                            0...8, 0x0a...0x1f, 0x7f => return error.InvalidChar,
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
                    self.cursor -= 1;
                    return if (key_mode) self.scanLiteral() else self.scanNonstringLiteral();
                },
            }
        }
    }

    /// Get the next token in the TOML document with the key mode enabled.
    fn nextKey(self: *@This()) !Token {
        return self.next(true);
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
                        return error.UnexpectedToken;
                    }
                } else {
                    break;
                }
            }

            var c = self.nextChar();

            if (c == end_of_input) {
                return error.UnexpectedEndOfInput;
            }

            if (c != '\\') {
                if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
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
                    return error.UnexpectedToken;
                }
            }

            if (c == '\n') {
                while (self.matchAny(" \t\n")) {
                    _ = self.nextChar();
                }
                continue;
            }

            return error.UnexpectedToken;
        }

        // TODO: Need for allocation?
        const result: Token = .{ .multiline_string = self.input[start..self.cursor] };

        assert(self.matchN('"', 3));
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
                        return error.UnexpectedToken;
                    }
                }
                continue;
            }

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
                return error.UnexpectedEndOfInput;
            }

            if (!(isValidChar(c) or mem.indexOfScalar(u8, " \t\n", c) != null)) {
                return error.UnexpectedToken;
            }
        }

        // TODO: Need for allocation?
        const result: Token = .{ .multiline_literal_string = self.input[start..self.cursor] };

        assert(self.matchN('\'', 3));
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
                return error.UnexpectedEndOfInput;
            }

            if (!(isValidChar(c) or c == '\t')) {
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
            // TODO: Sane handling for overflows.
            val = val * 10 + (self.input[self.cursor] - '0');
        }
        return val;
    }

    /// Read a time in the HH:MM:SS.fraction format from the upcoming
    /// characters.
    fn readTime(self: *@This()) !Time {
        var ret: Time = .{ .hour = undefined, .minute = undefined, .second = undefined };
        var start = self.cursor;

        ret.hour = self.readInt(u8);
        if (self.cursor - start != 2 or self.input[self.cursor] != ':') {
            return error.InvalidTime;
        }

        self.cursor += 1;
        start = self.cursor;

        ret.minute = self.readInt(u8);
        if (self.cursor - start != 2 or self.input[self.cursor] != ':') {
            return error.InvalidTime;
        }

        self.cursor += 1;
        start = self.cursor;

        ret.second = self.readInt(u8);
        if (self.cursor - start != 2) {
            return error.InvalidTime;
        }

        if (self.cursor >= self.end or self.input[self.cursor] != '.') {
            return ret;
        }

        self.cursor += 1;
        ret.nano = 0;
        var i: usize = 0;
        while (self.cursor < self.end and ascii.isDigit(self.input[self.cursor]) and i < 9) : (self.cursor += 1) {
            ret.nano = ret.nano * 10 + (self.input[self.cursor] - '0');
            i += 1;
        }

        while (i < 9) : (i += 1) {
            ret.nano *= 10;
        }

        return ret;
    }

    /// Read a date in the YYYY-MM-DD format from the upcoming characters.
    fn readDate(self: *@This()) !Date {
        const date_start = self.cursor;
        var ret: Date = .{ .year = undefined, .month = undefined, .day = undefined };
        var start = self.cursor;

        ret.year = self.readInt(u16);
        if (self.cursor - start != 4 or self.input[self.cursor] != '-') {
            return error.InvalidDate;
        }

        self.cursor += 1;
        start = self.cursor;

        ret.month = self.readInt(u8);
        if (self.cursor - start != 2 or self.input[self.cursor] != '-') {
            return error.InvalidDate;
        }

        self.cursor += 1;
        start = self.cursor;

        ret.day = self.readInt(u8);
        if (self.cursor - start != 2) {
            return error.InvalidDate;
        }

        assert(self.cursor - date_start == 10);

        return ret;
    }

    /// Read a timezone from the next characters.
    fn readTimezone(self: *@This()) !?i16 {
        const c = self.input[self.cursor];
        if (c == 'Z' or c == 'z') {
            self.cursor += 1;
            return 0; // UTC+00:00
        }

        const sign = switch (c) {
            '+' => 1,
            '-' => -1,
            else => return null,
        };

        self.cursor += 1;
        var start = self.cursor;

        const hour = self.readInt(i16);
        if (self.cursor - start != 2 or self.input[self.cursor] != ':') {
            return error.InvalidDatetime;
        }

        self.cursor += 1;
        start = self.cursor;

        const minute = self.readInt(i16);
        if (self.cursor - start != 2) {
            return error.InvalidDatetime;
        }

        return (hour * 60 + minute) * sign;
    }

    /// Scan upcoming local time value.
    fn scanTime(self: *@This()) !Token {
        const t = try self.readTime();
        if (!t.isValid()) {
            return error.InvalidTime;
        }

        return .{ .local_time = t };
    }

    /// Scan an upcoming datetime value.
    fn scanDatetime(self: *@This()) !Token {
        if (self.cursor + 2 >= self.end) {
            return error.UnexpectedEndOfInput;
        }

        if (ascii.isDigit(self.input[self.cursor]) and
            ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':')
        {
            const t = try self.readTime();
            if (!t.isValid()) {
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
                return error.InvalidDatetime;
            }

            return .{ .local_datetime = dt };
        }

        dt.tz = tz;
        if (!dt.isValid()) {
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
            return error.UnexpectedToken;
        }

        return .{ .bool = val };
    }

    /// Scan a possible upcoming number, i.e. integer or float.
    fn scanNumber(self: *@This()) !Token {
        if (self.input[self.cursor] == '0' and self.cursor + 1 < self.end) {
            const base, const span = switch (self.input[self.cursor + 1]) {
                'x' => .{ 16, "_0123456789abcdefABCDEF" },
                'o' => .{ 8, "_01234567" },
                'b' => .{ 2, "_01" },
                else => .{ null, null },
            };

            if (base) |b| {
                self.cursor += 2;
                if (self.cursor >= self.end) {
                    return error.UnexpectedEndOfInput;
                }

                const start = self.cursor;
                const i = mem.indexOfNonePos(u8, self.input, start, span) orelse return error.UnexpectedToken;
                const len = i - start;
                if (!self.checkNumberStr(len, b)) {
                    return error.InvalidNumber;
                }

                const n = try std.fmt.parseInt(i64, self.input[start .. start + len], b);
                return .{ .int = n };
            }
        }

        const start = self.cursor;
        var idx = self.cursor;
        if (self.input[idx] == '+' or self.input[idx] == '-') {
            idx += 1;
        }

        if (self.input[idx] == 'i' or self.input[idx] == 'n') {
            return self.scanFloat();
        }

        idx = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse return error.UnexpectedToken;

        if (!self.checkNumberStr(idx - start, 10)) {
            return error.InvalidNumber;
        }

        const n = std.fmt.parseInt(i64, self.input[start..idx], 10) catch |err| switch (err) {
            error.InvalidCharacter => if (mem.indexOfAnyPos(u8, self.input, idx, ".eE") != null) {
                return self.scanFloat();
            } else {
                return err;
            },
            else => return err,
        };

        self.cursor = idx;

        return .{ .int = n };
    }

    /// Scan a possible upcoming floating-point literal.
    fn scanFloat(self: *@This()) !Token {
        const start = self.cursor;
        if (self.input[self.cursor] == '+' or self.input[self.cursor] == '-') {
            self.cursor += 1;
        }

        if (mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "inf") or mem.eql(u8, self.input[self.cursor .. self.cursor + 3], "nan")) {
            self.cursor += 3;
        } else {
            self.cursor = mem.indexOfNonePos(u8, self.input, self.cursor, "_0123456789eE.+-") orelse return error.UnexpectedToken;
        }

        if (!self.checkNumberStr(self.cursor - start, 10)) {
            return error.InvalidNumber;
        }

        const f = try std.fmt.parseFloat(f64, self.input[start..self.cursor]);
        return .{ .float = f };
    }

    fn checkNumberStr(self: *@This(), len: usize, base: comptime_int) bool {
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
                if (i == 0 or !ascii.isDigit(self.input[self.cursor - 1] or !ascii.isDigit(self.input[self.cursor + 1]))) {
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
    root_table: *ParsingTable = undefined,
    current_table: *ParsingTable = undefined,

    const ParsingTable = std.StringArrayHashMap(ParsingValue);

    const ParsingValue = struct {
        flag: u8,
        value: union(enum) {
            table: ParsingTable,
        },
    };

    fn init(allocator: Allocator, scanner: *Scanner, root: *ParsingTable) @This() {
        return .{
            .allocator = allocator,
            .scanner = scanner,
            .root_table = root,
            .current_table = root,
        };
    }

    /// Descend to the final table represented by `keys` starting from the root
    /// table. If a table for a key does not exist, it will be created.
    /// The function returns the final table represented by the keys.
    fn descendToTable(self: *@This(), keys: [][]const u8) void {
        var table = self.root_table;

        for (keys) |key| {
            var table_value = table.get(key);
            if (table_value == null) {}
        }
    }

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
            return token;
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
                    const len = if (c == 'u') 4 else 8;
                    const s = orig[i .. i + len];
                    const codepoint = std.fmt.parseInt(u21, s, 16);
                    var buf: [4]u8 = undefined;
                    const n = try std.unicode.utf8Encode(codepoint, &buf);
                    try dst.appendSlice(buf[0..n]);
                    i += len;
                },
                ' ', '\t', '\r', '\n' => {
                    if (c != '\n') {
                        i += mem.indexOfNonePos(u8, orig, i, " \t\r") orelse 0;
                        if (orig[i] != '\n') {
                            return error.UnexpectedToken;
                        }
                    }

                    i += mem.indexOfNonePos(u8, orig, i, " \t\r\n") orelse 0;
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
                .literal, .string, .multiline_string => {}, // continue
                else => return error.UnexpectedToken,
            }

            try key_parts.append(try self.normalizeString(next_token));
        }

        return key_parts.toOwnedSlice();
    }

    /// Parse standard table header expression and set the new table as
    /// the current table in the parser.
    fn parseTableExpression(self: *@This()) !void {
        const keys = try self.parseKey();

        const next_token = try self.scanner.nextKey();
        if (next_token != .right_bracket) {
            return error.UnexpectedToken;
        }

        const last_key = keys[keys.len - 1];
    }
};

pub fn parse(allocator: Allocator, input: []const u8) !Value {
    // TODO: Maybe add an option to skip the UTF-8 validation for faster
    // parsing.
    if (!utf8Validate(input)) {
        return error.InvalidUtf8;
    }

    var parsing_root: Parser.ParsingValue = .{ .flag = 0, .value = .{ .table = .init(allocator) } };
    var scanner = Scanner.initCompleteInput(input);
    var parser = Parser.init(allocator, &scanner, &parsing_root.value.table);

    // Set an upper limit for the loop for safety. There cannot be more tokens
    // than there are characters in the input. If the input is streamed, this
    // needs changing.
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const token = scanner.nextKey();
        if (token == .end_of_file) {
            break;
        }

        switch (token) {
            .line_feed => continue,
            .left_bracket => try parser.parseTableExpression(),
            .end_of_file => unreachable,
        }
    }

    return Value{};
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
