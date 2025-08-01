const std = @import("std");
const assert = std.debug.assert;

/// Represents any TOML value that potentially contains other TOML values.
/// The result for parsing a TOML document is a `Value` that represents the root
/// table of the document.
const Value = union(enum) {};

const Token = union(enum) {
    dot,
    equal,
    comma,
    left_bracket,
    double_left_bracket,
    right_bracket,
    double_right_bracket,
    left_brace,
    right_brace,

    literal: []const u8,
    string: []const u8,
    multiline_string: []const u8,
    literal_string: []const u8,
    multiline_literal_string: []const u8,

    local_time: Time,

    line_feed,
    end_of_file,
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
    line: u64 = 0,

    /// Constant that marks the end of input when scanning for the next
    /// character.
    const end_of_input: u8 = 0;

    /// Initialize a `Scanner` with the complete TOML document input as a single
    /// slice.
    fn initCompleteInput(input: []const u8) @This() {
        return .{
            .input = input,
        };
    }

    fn isValidChar(c: u8) bool {
        return std.ascii.isPrint(c) or (c & 0x80);
    }

    /// Check if the next character matches c.
    fn match(self: *const @This(), c: u8) bool {
        if (self.cursor < self.input.len and self.input[self.cursor] == c) {
            return true;
        }

        if (c == '\n' and self.cursor + 1 < self.input.len) {
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

        if (self.cursor + n >= self.input.len) {
            return false;
        }

        var i: usize = 0;
        while (i < n and self.input[self.cursor + i]) : (i += 1) {}

        return i == n;
    }

    /// Check if the next token might be a time.
    fn matchTime(self: *const @This()) bool {
        return self.cursor + 2 < self.input.len and std.ascii.isDigit(self.input[self.cursor]) and
            std.ascii.isDigit(self.input[self.cursor + 1]) and self.input[self.cursor + 2] == ':';
    }

    /// Check if the next token might be a date.
    fn matchDate(self: *const @This()) bool {
        return self.cursor + 4 < self.input.len and std.ascii.isDigit(self.input[self.cursor]) and
            std.ascii.isDigit(self.input[self.cursor + 1]) and
            std.ascii.isDigit(self.input[self.cursor + 2]) and
            std.ascii.isDigit(self.input[self.cursor + 3]) and
            self.input[self.cursor + 4] == '-';
    }

    /// Get the next character in the input. It returns '\0' when it finds
    /// the end of input regardless of whether the input is null-terminated.
    fn nextChar(self: *@This()) u8 {
        var ret: u8 = end_of_input;

        if (self.cursor < self.input.len) {
            ret = self.input[self.cursor];
            self.cursor += 1;

            if (ret == '\r' and self.cursor < self.input.len and self.input[self.cursor] == '\n') {
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
        while (self.cursor < self.input.len) {
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
    fn nextKey(self: *@This()) Token {
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

        while (self.cursor < self.input.len) { // force upper limit to loop
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
                if (!(isValidChar(c) or std.mem.indexOfScalar(u8, " \t\n", c) != null)) {
                    return error.UnexpectedToken;
                }

                continue;
            }

            if (std.mem.indexOfScalar(u8, "\"\\bfnrt", c) != null) {
                continue; // skip the "normal" escape sequences
            }

            if (c == 'u' or c == 'U') {
                const len: usize = if (c == 'u') 4 else 8;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    if (!std.ascii.isHex(self.nextChar())) {
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
            if (std.mem.indexOfScalar(u8, "\"\\bfnrt", c) != null) {
                continue; // skip the "normal" escape sequences
            }

            if (c == 'u' or c == 'U') {
                const len: usize = if (c == 'u') 4 else 8;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    if (!std.ascii.isHex(self.nextChar())) {
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

        while (self.cursor < self.input.len) { // force upper limit to loop
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

            if (!(isValidChar(c) or std.mem.indexOfScalar(u8, " \t\n", c) != null)) {
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
    }

    /// Scan an upcoming literal, for example a key.
    fn scanLiteral(self: *@This()) Token {
        const start = self.cursor;
        while (self.cursor < self.input.len and (std.ascii.isAlphanumeric(self.input[self.cursor]) or self.input[self.cursor] == '_' or self.input[self.cursor] == '-')) : (self.cursor += 1) {}
        return .{ .literal = self.input[start..self.cursor] };
    }

    /// Read an integer value from the upcoming characters without the sign.
    fn readInt(self: *@This(), comptime T: type) T {
        var val: T = 0;
        while (std.ascii.isDigit(self.input[self.cursor])) : (self.cursor += 1) {
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

        self.cursor += 1;

        if (self.cursor >= self.input.len or self.input[self.cursor] != '.') {
            return ret;
        }

        self.cursor += 1;
        var factor = 100000;
        while (self.cursor < self.input.len and std.ascii.isDigit(self.input[self.cursor] and factor != 0)) : (self.cursor += 1) {
            ret.nano = (self.input[self.cursor] - '0') * factor;
            factor /= 10;
        }

        return ret;
    }

    /// Scan upcoming local time value.
    fn scanTime(self: *@This()) !Token {
        const t = try self.readTime();
        if (!t.isValid()) {
            return error.InvalidTime;
        }

        return .{ .local_time = t };
    }

    /// Scan upcoming datetime value.
    fn scanDatetime(self: *@This()) !Token {}
};

/// The parsing state.
const Parser = struct {
    scanner: Scanner,
    root_table: Value,
    current_table: Value,

    fn init() @This() {
        return .{};
    }

    /// Parse a multipart key.
    fn parseKey(self: *@This()) void {}

    /// Parse standard table header expression and set the new table as
    /// the current table in the parser.
    fn parseTableExpression(self: *@This()) void {
        const token = self.scanner.nextKey();
    }
};

pub fn parse(input: []const u8) !Value {
    // TODO: Maybe add an option to skip the UTF-8 validation for faster
    // parsing.
    if (!utf8Validate(input)) {
        return error.InvalidUtf8;
    }

    var parser = Parser.init();

    var scanner = Scanner.initCompleteInput(input);

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
            .left_bracket => {},
            .end_of_file => unreachable,
        }
    }

    return Value{};
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
