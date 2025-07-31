const std = @import("std");
const assert = std.debug.assert;

/// Represents any TOML value that potentially contains other TOML values.
/// The result for parsing a TOML document is a `Value` that represents the root
/// table of the document.
const Value = union(enum) {};

const Token = enum {
    dot,
    equal,
    comma,
    left_bracket,
    double_left_bracket,
    right_bracket,
    double_right_bracket,
    left_brace,
    right_brace,
    end_of_line,
    end_of_document,
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

    /// Check if the next character matches c.
    fn match(self: *@This(), c: u8) bool {
        if (self.cursor < self.input.len and self.input[self.cursor] == c) {
            return true;
        }

        if (c == '\n' and self.cursor + 1 < self.input.len) {
            return self.input[self.cursor] == '\r' and self.input[self.cursor + 1] == '\n';
        }

        return false;
    }

    /// Check if the next n characters match c.
    fn matchN(self: *@This(), c: u8, n: comptime_int) bool {
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
                return .end;
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
                    try self.scanString();
                },
                '\'' => {
                    self.cursor -= 1;
                    try self.scanLiteralString();
                },

                else => {
                    self.cursor -= 1;
                    // TODO: Scan literal.
                },
            }
        }
    }

    fn nextKey(self: *@This()) Token {
        return self.next(true);
    }

    fn scanString(self: *@This()) !Token {
        assert(self.match('"'));

        if (self.matchN('"', 3)) {
            // TODO: Multiline.
        }

        _ = self.nextChar(); // skip the opening quote

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

        assert(self.match('"'));
        _ = self.nextChar();

        // TODO: Real return value.
        return .string;
    }

    fn scanLiteralString(self: *@This()) !Token {
        assert(self.match('\''));

        if (self.matchN('\'', 3)) {
            // TODO: Multiline.
        }

        _ = self.nextChar(); // skip the opening quote

        while (!self.match('\'')) {
            const c = self.nextChar();
            if (c == end_of_input) {
                return error.UnexpectedEndOfInput;
            }

            if (!(isValidChar(c) or c == '\t')) {
                return error.UnexpectedToken;
            }
        }

        assert(self.match('\''));
        _ = self.nextChar();

        // TODO: Real return value.
        return .string;
    }

    fn isValidChar(c: u8) bool {
        return std.ascii.isPrint(c) or (c & 0x80);
    }
};

pub fn parse(input: []const u8) !Value {
    // TODO: Maybe add an option to skip the UTF-8 validation for faster
    // parsing.
    if (!utf8Validate(input)) {
        return error.InvalidUtf8;
    }

    var scanner = Scanner.initCompleteInput(input);

    // Set an upper limit for the loop for safety. There cannot be more tokens
    // than there are characters in the input. If the input is streamed, this
    // needs changing.
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const token = scanner.nextKey();
        if (token == .end_of_document) {
            break;
        }

        switch (token) {
            .end_of_line => continue,
            .end_of_document => unreachable,
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
