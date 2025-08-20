pub fn splitScalar(comptime T: type, comptime buffer: []const T, delimiter: T) [][]const T {
    var n: usize = 1;
    for (buffer) |b| {
        if (b == delimiter) {
            n += 1;
        }
    }

    var parts: [n][]const T = undefined;
    var start: usize = 0;
    var i: usize = 0;
    for (buffer, 0..) |b, j| {
        if (b == delimiter) {
            parts[i] = buffer[start..j];
            i += 1;
            start = j + 1;
        }
    }

    parts[i] = buffer[start..];

    return &parts;
}
