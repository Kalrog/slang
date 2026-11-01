//! string.format: printf-style formatting after Go's fmt package.
//!
//!   %v  any value as string() renders it      %s  a string (others as %v)
//!   %q  a quoted string with escapes          %t  a bool
//!   %d  an int (or a double without fraction) %c  the character of a code point
//!   %x %X %o %b  an int in base 16/8/2, as an unsigned 64-bit number; %x and
//!       %X of a string give the hex digits of its bytes
//!   %f %F %e %E %g %G  a number as a double   %%  a percent sign
//!
//! Flags: `-` pads on the right, `+` always writes a sign, ` ` writes a space
//! for a missing sign, `0` pads numbers with zeros, `#` adds 0x, 0X, 0 or 0b
//! and keeps trailing zeros of %g. Width and precision are numbers or `*`
//! (taken from the arguments). Width counts characters, not bytes; the
//! precision of %s and %q is the most characters to keep, of %d the fewest
//! digits, of %e and %f the digits after the point (6 by default) and of %g
//! the significant digits (the shortest exact form by default).

const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const Value = vm_mod.Value;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;

const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    zero: bool = false,
    sharp: bool = false,
    width: ?usize = null,
    prec: ?usize = null,
    verb: u8 = 'v',
};

const List = std.ArrayList(u8);

/// Formats the arguments of the current native call from index `first` on
/// with the format string fmt into out. Arguments are read from the stack
/// one at a time, because rendering a value may run __tostring, which can
/// move the stack.
pub fn format(th: *Thread, fmt: []const u8, first: usize, out: *List) Error!void {
    const gpa = th.vm.gpa;
    var argi = first;
    var field: List = .empty;
    defer field.deinit(gpa);
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c != '%') {
            const next = std.mem.indexOfScalarPos(u8, fmt, i, '%') orelse fmt.len;
            out.appendSlice(gpa, fmt[i..next]) catch oom();
            i = next;
            continue;
        }
        i += 1;
        if (i >= fmt.len) return th.vm.raise("format: the format ends with a lone %", .{});
        if (fmt[i] == '%') {
            out.append(gpa, '%') catch oom();
            i += 1;
            continue;
        }
        var spec: Spec = .{};
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '-' => spec.minus = true,
                '+' => spec.plus = true,
                ' ' => spec.space = true,
                '0' => spec.zero = true,
                '#' => spec.sharp = true,
                else => break,
            }
        }
        if (i < fmt.len and fmt[i] == '*') {
            spec.width = try countArg(th, &argi, "width");
            i += 1;
        } else {
            spec.width = number(fmt, &i);
        }
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            if (i < fmt.len and fmt[i] == '*') {
                spec.prec = try countArg(th, &argi, "precision");
                i += 1;
            } else {
                spec.prec = number(fmt, &i) orelse 0;
            }
        }
        if (i >= fmt.len) return th.vm.raise("format: the format ends inside a verb", .{});
        spec.verb = fmt[i];
        i += 1;
        if (argi >= th.nargs()) return th.vm.raise("format: no argument for %{c}", .{spec.verb});
        field.clearRetainingCapacity();
        const numeric = try verb(th, spec, argi, &field);
        argi += 1;
        pad(gpa, out, field.items, spec, numeric);
    }
    if (argi < th.nargs()) {
        return th.vm.raise("format: {d} arguments but the format uses {d}", .{ th.nargs() - first, argi - first });
    }
}

fn number(fmt: []const u8, i: *usize) ?usize {
    const start = i.*;
    while (i.* < fmt.len and std.ascii.isDigit(fmt[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseInt(usize, fmt[start..i.*], 10) catch null;
}

fn countArg(th: *Thread, argi: *usize, what: []const u8) Error!usize {
    if (argi.* >= th.nargs()) return th.vm.raise("format: no argument for the {s} *", .{what});
    const v = th.arg(argi.*);
    argi.* += 1;
    if (v != .int or v.int < 0) return th.vm.raise("format: the {s} * needs an int of 0 or more", .{what});
    return @intCast(v.int);
}

/// Writes the field of one verb; returns whether it is a number (for zero
/// padding, which goes after the sign and the base prefix).
fn verb(th: *Thread, spec: Spec, argi: usize, field: *List) Error!bool {
    const gpa = th.vm.gpa;
    const v = th.arg(argi);
    switch (spec.verb) {
        'v', 's' => {
            if (v == .float and spec.verb == 'v' and spec.prec != null) {
                try float(th, spec, v.float, 'g', field);
                return true;
            }
            const s = try render(th, v, field);
            truncate(field, s, spec.prec);
            return false;
        },
        'q' => {
            const start = field.items.len;
            _ = try render(th, v, field);
            const raw = gpa.dupe(u8, field.items[start..]) catch oom();
            defer gpa.free(raw);
            field.shrinkRetainingCapacity(start);
            quote(gpa, field, raw, spec.prec);
            return false;
        },
        't' => {
            if (v != .bool) return bad(th, spec.verb, "a bool", v);
            field.appendSlice(gpa, if (v.bool) "true" else "false") catch oom();
            return false;
        },
        'c' => {
            const n = try intOf(th, spec.verb, v);
            var buf: [4]u8 = undefined;
            const cp: u21 = if (n < 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF)) 0xFFFD else @intCast(n);
            const k = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            field.appendSlice(gpa, buf[0..k]) catch oom();
            return false;
        },
        'd' => {
            const n = try intOf(th, spec.verb, v);
            sign(gpa, field, n < 0, spec);
            var buf: [24]u8 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}) catch unreachable;
            minDigits(gpa, field, digits, spec.prec);
            return true;
        },
        'x', 'X', 'o', 'b' => {
            if (v == .string and (spec.verb == 'x' or spec.verb == 'X')) {
                const s = v.string.bytes();
                const digits = if (spec.verb == 'x') "0123456789abcdef" else "0123456789ABCDEF";
                if (spec.sharp) field.appendSlice(gpa, if (spec.verb == 'x') "0x" else "0X") catch oom();
                for (s) |b| field.appendSlice(gpa, &.{ digits[b >> 4], digits[b & 15] }) catch oom();
                return false;
            }
            const n = try intOf(th, spec.verb, v);
            const u: u64 = @bitCast(n);
            if (spec.plus) field.append(gpa, '+') catch oom() else if (spec.space) field.append(gpa, ' ') catch oom();
            if (spec.sharp) field.appendSlice(gpa, switch (spec.verb) {
                'x' => "0x",
                'X' => "0X",
                'o' => "0",
                else => "0b",
            }) catch oom();
            var buf: [72]u8 = undefined;
            const digits = switch (spec.verb) {
                'x' => std.fmt.bufPrint(&buf, "{x}", .{u}),
                'X' => std.fmt.bufPrint(&buf, "{X}", .{u}),
                'o' => std.fmt.bufPrint(&buf, "{o}", .{u}),
                else => std.fmt.bufPrint(&buf, "{b}", .{u}),
            } catch unreachable;
            minDigits(gpa, field, digits, spec.prec);
            return true;
        },
        'e', 'E', 'f', 'F', 'g', 'G' => {
            const x: f64 = switch (v) {
                .int => |n| @floatFromInt(n),
                .float => |f| f,
                else => return bad(th, spec.verb, "a number", v),
            };
            try float(th, spec, x, spec.verb, field);
            return true;
        },
        else => return th.vm.raise("format: unknown verb %{c}", .{spec.verb}),
    }
}

fn bad(th: *Thread, v: u8, want: []const u8, got: Value) Error {
    return th.vm.raise("format: %{c} needs {s}, got {s}", .{ v, want, got.typeName() });
}

fn intOf(th: *Thread, v: u8, x: Value) Error!i64 {
    return switch (x) {
        .int => |n| n,
        .float => |f| if (f == @trunc(f) and f >= -9.2e18 and f <= 9.2e18) @intFromFloat(f) else bad(th, v, "an int", x),
        else => bad(th, v, "an int", x),
    };
}

/// Appends v as string() renders it and returns the appended bytes' start.
fn render(th: *Thread, v: Value, field: *List) Error!usize {
    const gpa = th.vm.gpa;
    const start = field.items.len;
    switch (v) {
        .string => |s| field.appendSlice(gpa, s.bytes()) catch oom(),
        .int, .float, .bool, .null => {
            var buf: [64]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            vm_mod.format.writeValue(&w, v) catch unreachable;
            field.appendSlice(gpa, w.buffered()) catch oom();
        },
        else => {
            const s = try th.toString(v);
            field.appendSlice(gpa, s.bytes()) catch oom();
        },
    }
    return start;
}

/// Keeps at most prec characters of the field from start on.
fn truncate(field: *List, start: usize, prec: ?usize) void {
    const p = prec orelse return;
    var chars: usize = 0;
    var i = start;
    while (i < field.items.len) : (i += 1) {
        if (field.items[i] & 0xC0 != 0x80) {
            if (chars == p) {
                field.shrinkRetainingCapacity(i);
                return;
            }
            chars += 1;
        }
    }
}

fn quote(gpa: std.mem.Allocator, field: *List, s: []const u8, prec: ?usize) void {
    field.append(gpa, '"') catch oom();
    var chars: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (prec) |p| if (chars == p) break;
        chars += 1;
        const b = s[i];
        switch (b) {
            '"' => field.appendSlice(gpa, "\\\"") catch oom(),
            '\\' => field.appendSlice(gpa, "\\\\") catch oom(),
            '\n' => field.appendSlice(gpa, "\\n") catch oom(),
            '\r' => field.appendSlice(gpa, "\\r") catch oom(),
            '\t' => field.appendSlice(gpa, "\\t") catch oom(),
            else => {
                if (b < 0x20 or b == 0x7f) {
                    var buf: [4]u8 = undefined;
                    field.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{b}) catch unreachable) catch oom();
                } else if (b < 0x80) {
                    field.append(gpa, b) catch oom();
                } else {
                    const n = std.unicode.utf8ByteSequenceLength(b) catch 0;
                    if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                        field.appendSlice(gpa, s[i .. i + n]) catch oom();
                        i += n;
                        continue;
                    }
                    var buf: [4]u8 = undefined;
                    field.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{b}) catch unreachable) catch oom();
                }
            },
        }
        i += 1;
    }
    field.append(gpa, '"') catch oom();
}

fn sign(gpa: std.mem.Allocator, field: *List, negative: bool, spec: Spec) void {
    if (negative) {
        field.append(gpa, '-') catch oom();
    } else if (spec.plus) {
        field.append(gpa, '+') catch oom();
    } else if (spec.space) {
        field.append(gpa, ' ') catch oom();
    }
}

fn minDigits(gpa: std.mem.Allocator, field: *List, digits: []const u8, prec: ?usize) void {
    if (prec) |p| if (p > digits.len) field.appendNTimes(gpa, '0', p - digits.len) catch oom();
    field.appendSlice(gpa, digits) catch oom();
}

fn float(th: *Thread, spec: Spec, x: f64, v: u8, field: *List) Error!void {
    const gpa = th.vm.gpa;
    sign(gpa, field, std.math.signbit(x) and !std.math.isNan(x), spec);
    const a = @abs(x);
    if (std.math.isNan(x)) return field.appendSlice(gpa, "NaN") catch oom();
    if (std.math.isInf(x)) return field.appendSlice(gpa, "Infinity") catch oom();
    var buf: [400]u8 = undefined;
    const upper = v == 'E' or v == 'G';
    switch (v) {
        'f', 'F' => {
            const s = std.fmt.float.render(&buf, a, .{ .mode = .decimal, .precision = spec.prec orelse 6 }) catch unreachable;
            field.appendSlice(gpa, s) catch oom();
        },
        'e', 'E' => {
            const s = std.fmt.float.render(&buf, a, .{ .mode = .scientific, .precision = spec.prec orelse 6 }) catch unreachable;
            scientific(gpa, field, s, upper, true);
        },
        else => {
            // %g: the exponent of the rounded value decides between the forms
            if (spec.prec) |p0| {
                const p = @max(p0, 1);
                const sci = std.fmt.float.render(&buf, a, .{ .mode = .scientific, .precision = p - 1 }) catch unreachable;
                const exp = exponentOf(sci);
                if (exp < -4 or exp >= @as(i32, @intCast(p))) {
                    scientific(gpa, field, sci, upper, spec.sharp);
                } else {
                    var dbuf: [400]u8 = undefined;
                    const digits_after: usize = @intCast(@as(i32, @intCast(p)) - 1 - exp);
                    const s = std.fmt.float.render(&dbuf, a, .{ .mode = .decimal, .precision = digits_after }) catch unreachable;
                    field.appendSlice(gpa, if (spec.sharp) s else stripZeros(s)) catch oom();
                }
            } else {
                const sci = std.fmt.float.render(&buf, a, .{ .mode = .scientific }) catch unreachable;
                const exp = exponentOf(sci);
                if (exp < -4 or exp >= 21) {
                    scientific(gpa, field, sci, upper, true);
                } else {
                    var dbuf: [400]u8 = undefined;
                    const s = std.fmt.float.render(&dbuf, a, .{ .mode = .decimal }) catch unreachable;
                    field.appendSlice(gpa, s) catch oom();
                }
            }
        },
    }
}

fn exponentOf(sci: []const u8) i32 {
    const e = std.mem.indexOfScalar(u8, sci, 'e') orelse return 0;
    return std.fmt.parseInt(i32, sci[e + 1 ..], 10) catch 0;
}

fn stripZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var end = s.len;
    while (end > 0 and s[end - 1] == '0') end -= 1;
    if (end > 0 and s[end - 1] == '.') end -= 1;
    return s[0..end];
}

/// Zig's "1.5e2" as Go writes it, "1.5e+02"; trailing zeros of the mantissa
/// go unless keep.
fn scientific(gpa: std.mem.Allocator, field: *List, sci: []const u8, upper: bool, keep: bool) void {
    const e = std.mem.indexOfScalar(u8, sci, 'e') orelse return field.appendSlice(gpa, sci) catch oom();
    const mant = if (keep) sci[0..e] else stripZeros(sci[0..e]);
    field.appendSlice(gpa, mant) catch oom();
    field.append(gpa, if (upper) 'E' else 'e') catch oom();
    const exp = std.fmt.parseInt(i32, sci[e + 1 ..], 10) catch 0;
    field.append(gpa, if (exp < 0) '-' else '+') catch oom();
    var buf: [12]u8 = undefined;
    field.appendSlice(gpa, std.fmt.bufPrint(&buf, "{d:0>2}", .{@abs(exp)}) catch unreachable) catch oom();
}

/// Pads the field to the width: spaces on the left (on the right with -),
/// or zeros after the sign and base prefix for a number with the 0 flag.
fn pad(gpa: std.mem.Allocator, out: *List, field: []const u8, spec: Spec, numeric: bool) void {
    const w = spec.width orelse return out.appendSlice(gpa, field) catch oom();
    var chars: usize = 0;
    for (field) |b| {
        if (b & 0xC0 != 0x80) chars += 1;
    }
    if (chars >= w) return out.appendSlice(gpa, field) catch oom();
    const n = w - chars;
    if (spec.minus) {
        out.appendSlice(gpa, field) catch oom();
        out.appendNTimes(gpa, ' ', n) catch oom();
    } else if (spec.zero and numeric) {
        var k: usize = 0;
        if (k < field.len and (field[k] == '-' or field[k] == '+' or field[k] == ' ')) k += 1;
        if (k + 1 < field.len and field[k] == '0' and (field[k + 1] == 'x' or field[k + 1] == 'X' or field[k + 1] == 'b')) k += 2;
        // NaN and Infinity are padded with spaces
        if (k < field.len and !std.ascii.isDigit(field[k])) {
            out.appendNTimes(gpa, ' ', n) catch oom();
            out.appendSlice(gpa, field) catch oom();
            return;
        }
        out.appendSlice(gpa, field[0..k]) catch oom();
        out.appendNTimes(gpa, '0', n) catch oom();
        out.appendSlice(gpa, field[k..]) catch oom();
    } else {
        out.appendNTimes(gpa, ' ', n) catch oom();
        out.appendSlice(gpa, field) catch oom();
    }
}
