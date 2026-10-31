const std = @import("std");
const Value = @import("value.zig").Value;
const Table = @import("table.zig").Table;
const Writer = std.Io.Writer;

/// Writes a double the way Dart/JavaScript print numbers (shortest
/// round-trip digits, ".0" for integral values, exponent form outside
/// 1e-6 .. 1e21).
pub fn writeFloat(w: *Writer, f: f64) Writer.Error!void {
    if (std.math.isNan(f)) return w.writeAll("NaN");
    if (std.math.isPositiveInf(f)) return w.writeAll("Infinity");
    if (std.math.isNegativeInf(f)) return w.writeAll("-Infinity");
    if (f == 0) return w.writeAll(if (std.math.signbit(f)) "-0.0" else "0.0");

    var buf: [64]u8 = undefined;
    const sci = std.fmt.float.render(&buf, f, .{ .mode = .scientific }) catch unreachable;
    var s: []const u8 = sci;
    if (s[0] == '-') {
        try w.writeByte('-');
        s = s[1..];
    }
    const epos = std.mem.indexOfScalar(u8, s, 'e') orelse unreachable;
    const mant = s[0..epos];
    const exp = std.fmt.parseInt(i32, s[epos + 1 ..], 10) catch unreachable;
    // digits without the decimal point
    var digits_buf: [32]u8 = undefined;
    var k: usize = 0;
    for (mant) |c| {
        if (c != '.') {
            digits_buf[k] = c;
            k += 1;
        }
    }
    const digits = digits_buf[0..k];
    const n: i32 = exp + 1;
    const ki: i32 = @intCast(k);
    if (ki <= n and n <= 21) {
        try w.writeAll(digits);
        try w.splatByteAll('0', @intCast(n - ki));
        try w.writeAll(".0");
    } else if (0 < n and n <= 21) {
        try w.writeAll(digits[0..@intCast(n)]);
        try w.writeByte('.');
        try w.writeAll(digits[@intCast(n)..]);
    } else if (-6 < n and n <= 0) {
        try w.writeAll("0.");
        try w.splatByteAll('0', @intCast(-n));
        try w.writeAll(digits);
    } else {
        const e = n - 1;
        try w.writeByte(digits[0]);
        if (k > 1) {
            try w.writeByte('.');
            try w.writeAll(digits[1..]);
        }
        try w.writeByte('e');
        try w.writeByte(if (e < 0) '-' else '+');
        try w.print("{d}", .{@abs(e)});
    }
}

/// Renders a value the way the Dart implementation did (used by print and
/// string conversion). Tables are rendered structurally.
pub fn writeValue(w: *Writer, v: Value) Writer.Error!void {
    return writeValueDepth(w, v, 0);
}

fn writeValueDepth(w: *Writer, v: Value, depth: usize) Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try writeFloat(w, f),
        .string => |s| try w.writeAll(s.bytes()),
        .table => |t| try writeTable(w, t, depth),
        .function => |c| try w.writeAll(if (c.isNative()) "native function" else "function"),
        .userdata => |u| {
            if (u.to_string) |f| try f(u, w) else try w.writeAll("userdata");
        },
        .thread => try w.writeAll("thread"),
    }
}

fn writeTable(w: *Writer, t: *const Table, depth: usize) Writer.Error!void {
    if (t.meta) |m| {
        const ty = m.getName("__type");
        if (ty == .string) {
            try w.writeByte('\'');
            try w.writeAll(ty.string.bytes());
        }
    }
    if (depth > 32) return w.writeAll("{...}");
    try w.writeByte('{');
    var first = true;
    for (t.arr.items, 0..) |v, i| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{d}: ", .{i});
        try writeValueDepth(w, v, depth + 1);
    }
    for (t.ents.items) |e| {
        if (e.key == .null) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try writeValueDepth(w, e.key, depth + 1);
        try w.writeAll(": ");
        try writeValueDepth(w, e.val, depth + 1);
    }
    try w.writeByte('}');
}

/// Renders a value into a newly allocated byte slice.
pub fn valueToOwned(gpa: std.mem.Allocator, v: Value) []u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeValue(&aw.writer, v) catch @panic("out of memory");
    return aw.toOwnedSlice() catch @panic("out of memory");
}

fn expectFloat(expected: []const u8, f: f64) !void {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeFloat(&w, f);
    try std.testing.expectEqualStrings(expected, w.buffered());
}

test "float formatting follows Dart" {
    try expectFloat("1.0", 1.0);
    try expectFloat("0.1", 0.1);
    try expectFloat("-2.5", -2.5);
    try expectFloat("100.0", 100.0);
    try expectFloat("1e+21", 1e21);
    try expectFloat("100000000000000000000.0", 1e20);
    try expectFloat("0.000001", 1e-6);
    try expectFloat("1e-7", 1e-7);
    try expectFloat("1.5e-7", 1.5e-7);
    try expectFloat("1.2345678901234569e+23", 123456789012345678901234.0);
    try expectFloat("3.141592653589793", std.math.pi);
    try expectFloat("NaN", std.math.nan(f64));
    try expectFloat("-Infinity", -std.math.inf(f64));
    try expectFloat("-0.0", -0.0);
    try expectFloat("5e-324", 5e-324);
}
