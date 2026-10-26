//! slang/string. Strings are byte strings (UTF-8 by convention); positions
//! are byte offsets.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const String = vm_mod.String;
const Thread = vm_mod.Thread;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "join", .f = strJoin },
        .{ .name = "substring", .f = strSubstring },
        .{ .name = "byte_at", .f = strByteAt },
        .{ .name = "char_at", .f = strCharAt },
        .{ .name = "chr", .f = strChr },
        .{ .name = "from_bytes", .f = strFromBytes },
        .{ .name = "index_of", .f = strIndexOf },
        .{ .name = "starts_with", .f = strStartsWith },
        .{ .name = "ends_with", .f = strEndsWith },
        .{ .name = "line_starts", .f = strLineStarts },
        .{ .name = "split", .f = strSplit },
        .{ .name = "trim", .f = strTrim },
        .{ .name = "upper", .f = strUpper },
        .{ .name = "lower", .f = strLower },
        .{ .name = "replace", .f = strReplace },
        .{ .name = "to_number", .f = strToNumber },
        .{ .name = "char_class", .f = strCharClass },
        .{ .name = "class_match", .f = strClassMatch },
        .{ .name = "class_run", .f = strClassRun },
        .{ .name = "line_col", .f = strLineCol },
        .{ .name = "space_at", .f = strSpaceAt },
        .{ .name = "skip_space", .f = strSkipSpace },
        .{ .name = "rune_len_at", .f = strRuneLenAt },
        .{ .name = "compare", .f = strCompare },
        .{ .name = "hash", .f = strHash },
    });
}

const Rune = struct { r: u21, len: usize };

/// Decodes the UTF-8 character at pos like Go's DecodeRuneInString: an
/// invalid sequence yields U+FFFD with length 1.
pub fn decodeRune(s: []const u8, pos: usize) Rune {
    const b = s[pos];
    if (b < 0x80) return .{ .r = b, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .r = 0xFFFD, .len = 1 };
    if (pos + n > s.len) return .{ .r = 0xFFFD, .len = 1 };
    const r = std.unicode.utf8Decode(s[pos .. pos + n]) catch return .{ .r = 0xFFFD, .len = 1 };
    return .{ .r = r, .len = n };
}

/// Go's unicode.IsSpace.
fn isUnicodeSpace(r: u21) bool {
    return switch (r) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85, 0xA0 => true,
        0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
}

fn isAsciiSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == 0x0c or b == 0x0b;
}

fn strJoin(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    const sep = api.argStringOr(args, 1, " ");
    var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
    defer aw.deinit();
    var first = true;
    var it = t.iterator();
    while (it.next()) |e| {
        const s = e.val.asBytes() orelse {
            const shown = vm_mod.format.valueToOwned(th.vm.gpa, e.val);
            defer th.vm.gpa.free(shown);
            return th.vm.raise("expected string, got {s}", .{shown});
        };
        if (!first) aw.writer.writeAll(sep) catch oom();
        first = false;
        aw.writer.writeAll(s) catch oom();
    }
    return th.vm.str(aw.writer.buffered());
}

fn strSubstring(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const start = api.argIntOr(args, 1, 0);
    const end = api.argIntOr(args, 2, @intCast(s.len));
    if (start < 0 or end > s.len or start > end) {
        return th.vm.raise("substring range {d}..{d} out of bounds for length {d}", .{ start, end, s.len });
    }
    return th.vm.str(s[@intCast(start)..@intCast(end)]);
}

/// byte_at(s, i): the byte at i as an int, or null when out of range.
fn strByteAt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const i = api.argIntOr(args, 1, -1);
    if (i < 0 or i >= s.len) return .null;
    return .{ .int = s[@intCast(i)] };
}

/// char_at(s, i): the UTF-8 character starting at byte i, or null.
fn strCharAt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const i = api.argIntOr(args, 1, -1);
    if (i < 0 or i >= s.len) return .null;
    const pos: usize = @intCast(i);
    const r = decodeRune(s, pos);
    return th.vm.str(s[pos .. pos + r.len]);
}

/// chr(code): the character with the given code point.
fn strChr(th: *Thread, args: []Value) Error!Value {
    const c = try api.argInt(th, args, 0, "code");
    if (c >= 0 and c < 128) return th.vm.str(&[_]u8{@intCast(c)});
    var buf: [4]u8 = undefined;
    // Go's string(rune) turns invalid code points into U+FFFD
    const cp: u21 = if (c < 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF)) 0xFFFD else @intCast(c);
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    return th.vm.str(buf[0..n]);
}

/// index_of(s, sub, [from]): byte index of sub in s at or after from, or -1.
fn strIndexOf(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const sub = try api.argString(th, args, 1, "sub");
    var from = api.argIntOr(args, 2, 0);
    if (from < 0) from = 0;
    if (from > s.len) return .{ .int = -1 };
    const f: usize = @intCast(from);
    const i = std.mem.indexOf(u8, s[f..], sub) orelse return .{ .int = -1 };
    return .{ .int = @intCast(f + i) };
}

/// starts_with(s, prefix, [at]): whether s has prefix at byte offset at.
fn strStartsWith(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const prefix = try api.argString(th, args, 1, "prefix");
    const at = api.argIntOr(args, 2, 0);
    if (at < 0 or at > s.len) return .{ .bool = false };
    return .{ .bool = std.mem.startsWith(u8, s[@intCast(at)..], prefix) };
}

fn strEndsWith(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const suffix = try api.argString(th, args, 1, "suffix");
    return .{ .bool = std.mem.endsWith(u8, s, suffix) };
}

/// line_starts(s): byte offsets at which each line starts (first entry is 0).
fn strLineStarts(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const t = th.vm.newTable(std.mem.count(u8, s, "\n") + 1, 0);
    t.append(th.vm.gpa, .{ .int = 0 });
    for (s, 0..) |c, i| {
        if (c == '\n') t.append(th.vm.gpa, .{ .int = @intCast(i + 1) });
    }
    return .{ .table = t };
}

fn strSplit(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const s = try api.argString(th, args, 0, "str");
    const sep = try api.argString(th, args, 1, "sep");
    const t = vm.newTable(0, 0);
    if (sep.len == 0) {
        // Go splits into UTF-8 characters
        var pos: usize = 0;
        while (pos < s.len) {
            const r = decodeRune(s, pos);
            t.append(vm.gpa, vm.str(s[pos .. pos + r.len]));
            pos += r.len;
        }
        return .{ .table = t };
    }
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |part| t.append(vm.gpa, vm.str(part));
    return .{ .table = t };
}

fn strTrim(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        const r = decodeRune(s, start);
        if (!isUnicodeSpace(r.r)) break;
        start += r.len;
    }
    while (end > start) {
        // walk back to the start of the last character
        var p = end - 1;
        while (p > start and (s[p] & 0xC0) == 0x80) p -= 1;
        const r = decodeRune(s, p);
        if (!isUnicodeSpace(r.r)) break;
        end = p;
    }
    return th.vm.str(s[start..end]);
}

fn strUpper(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const out = th.vm.newStringUninit(s.len);
    _ = std.ascii.upperString(out.mutableBytes(), s);
    return .{ .string = out };
}

fn strLower(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const out = th.vm.newStringUninit(s.len);
    _ = std.ascii.lowerString(out.mutableBytes(), s);
    return .{ .string = out };
}

fn strReplace(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const old = try api.argString(th, args, 1, "old");
    const repl = try api.argString(th, args, 2, "new");
    if (old.len == 0) return api.arg(args, 0);
    const out = std.mem.replaceOwned(u8, th.vm.gpa, s, old, repl) catch oom();
    defer th.vm.gpa.free(out);
    return th.vm.str(out);
}

/// to_number(s): parses an int or a double, or returns null.
fn strToNumber(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var body = s;
    var neg = false;
    if (body.len > 0 and (body[0] == '-' or body[0] == '+')) {
        neg = body[0] == '-';
        body = body[1..];
    }
    if (@import("core.zig").parseIntStrict(body, 10)) |i| return .{ .int = if (neg) 0 -% i else i };
    if (std.fmt.parseFloat(f64, s)) |f| return .{ .float = f } else |_| {}
    return .null;
}

/// A compiled character class in petitparser pattern syntax: ranges like
/// a-z, single characters, and a leading ^ for negation.
const CharClass = struct {
    gpa: std.mem.Allocator,
    negate: bool,
    ranges: []u21, // pairs lo, hi
    spec: []u8,

    fn match(c: *const CharClass, r: u21) bool {
        var hit = false;
        var i: usize = 0;
        while (i + 1 < c.ranges.len) : (i += 2) {
            if (r >= c.ranges[i] and r <= c.ranges[i + 1]) {
                hit = true;
                break;
            }
        }
        return hit != c.negate;
    }
};

const class_tname = "char_class";

fn classFinalize(data: ?*anyopaque) callconv(.c) void {
    const c: *CharClass = @ptrCast(@alignCast(data.?));
    c.gpa.free(c.ranges);
    c.gpa.free(c.spec);
}

fn classToString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("[{s}]", .{u.as(CharClass).spec});
}

fn compileCharClass(vm: *VM, spec: []const u8) CharClass {
    var runes: std.ArrayList(u21) = .empty;
    defer runes.deinit(vm.gpa);
    var pos: usize = 0;
    while (pos < spec.len) {
        const r = decodeRune(spec, pos);
        runes.append(vm.gpa, r.r) catch oom();
        pos += r.len;
    }
    const rs = runes.items;
    var ranges: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    var negate = false;
    if (rs.len > 0 and rs[0] == '^') {
        negate = true;
        i = 1;
    }
    while (i < rs.len) {
        const lo = rs[i];
        if (i + 2 < rs.len and rs[i + 1] == '-') {
            ranges.appendSlice(vm.gpa, &.{ lo, rs[i + 2] }) catch oom();
            i += 3;
            continue;
        }
        ranges.appendSlice(vm.gpa, &.{ lo, lo }) catch oom();
        i += 1;
    }
    return .{
        .gpa = vm.gpa,
        .negate = negate,
        .ranges = ranges.toOwnedSlice(vm.gpa) catch oom(),
        .spec = vm.gpa.dupe(u8, spec) catch oom(),
    };
}

/// char_class(spec): compiles a character class.
fn strCharClass(th: *Thread, args: []Value) Error!Value {
    const spec = try api.argString(th, args, 0, "spec");
    const u = th.vm.newUserdataOf(CharClass, compileCharClass(th.vm, spec), class_tname, null);
    u.finalizer = classFinalize;
    u.to_string = classToString;
    return .{ .userdata = u };
}

/// class_match(class, s, pos): byte length of the character at pos if it is
/// in the class, otherwise 0.
fn strClassMatch(th: *Thread, args: []Value) Error!Value {
    const c = try api.argUserdata(th, args, 0, "class", CharClass, class_tname);
    const s = try api.argString(th, args, 1, "str");
    const pos = api.argIntOr(args, 2, 0);
    if (pos < 0 or pos >= s.len) return .{ .int = 0 };
    const r = decodeRune(s, @intCast(pos));
    return .{ .int = if (c.match(r.r)) @intCast(r.len) else 0 };
}

/// class_run(class, s, pos): the position after the longest run of
/// characters in the class starting at pos (pos itself when there is none).
fn strClassRun(th: *Thread, args: []Value) Error!Value {
    const c = try api.argUserdata(th, args, 0, "class", CharClass, class_tname);
    const s = try api.argString(th, args, 1, "str");
    var pos: usize = @intCast(@max(0, api.argIntOr(args, 2, 0)));
    while (pos < s.len) {
        const b = s[pos];
        if (b < 0x80) {
            if (!c.match(b)) break;
            pos += 1;
            continue;
        }
        const r = decodeRune(s, pos);
        if (!c.match(r.r)) break;
        pos += r.len;
    }
    return .{ .int = @intCast(pos) };
}

/// The line starts of the most recently used buffer (parsers call line_col
/// once per token on the same buffer). The string is kept alive through the
/// VM's registry so the pointer comparison stays valid.
fn lineStartsOf(vm: *VM, s: *String) []const u32 {
    if (vm.line_cache_str == s) return vm.line_cache.items;
    vm.line_cache.clearRetainingCapacity();
    vm.line_cache.append(vm.gpa, 0) catch oom();
    for (s.bytes(), 0..) |c, i| {
        if (c == '\n') vm.line_cache.append(vm.gpa, @intCast(i + 1)) catch oom();
    }
    vm.line_cache_str = s;
    vm.registry.set(vm.gpa, vm.str("line_cache"), .{ .string = s });
    return vm.line_cache.items;
}

/// line_col(s, pos): {line, column} (1-based) of byte offset pos.
fn strLineCol(th: *Thread, args: []Value) Error!Value {
    const sv = api.arg(args, 0);
    const str = sv.asString() orelse return api.argError(th, "str", 0, "String", sv);
    const pos: u32 = @intCast(@max(0, api.argIntOr(args, 1, 0)));
    const starts = lineStartsOf(th.vm, str);
    // first index whose start is > pos, minus one
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] > pos) hi = mid else lo = mid + 1;
    }
    const line: usize = if (lo == 0) 0 else lo - 1;
    const t = th.vm.newTable(2, 0);
    t.append(th.vm.gpa, .{ .int = @intCast(line + 1) });
    t.append(th.vm.gpa, .{ .int = @as(i64, pos) - starts[line] + 1 });
    return .{ .table = t };
}

/// space_at(s, pos): byte length of the whitespace character at pos, or 0.
fn strSpaceAt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const pos = api.argIntOr(args, 1, 0);
    if (pos < 0 or pos >= s.len) return .{ .int = 0 };
    const p: usize = @intCast(pos);
    if (s[p] < 0x80) return .{ .int = if (isAsciiSpace(s[p])) 1 else 0 };
    const r = decodeRune(s, p);
    return .{ .int = if (isUnicodeSpace(r.r)) @intCast(r.len) else 0 };
}

/// skip_space(s, pos): the position after any run of whitespace and line
/// comments (// up to, not including, the newline) starting at pos.
fn strSkipSpace(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var pos: usize = @intCast(@max(0, api.argIntOr(args, 1, 0)));
    const n = s.len;
    while (pos < n) {
        const b = s[pos];
        if (isAsciiSpace(b)) {
            pos += 1;
            continue;
        }
        if (b == '/' and pos + 1 < n and s[pos + 1] == '/') {
            pos += 2;
            while (pos < n and s[pos] != '\n') pos += 1;
            continue;
        }
        if (b >= 0x80) {
            const r = decodeRune(s, pos);
            if (isUnicodeSpace(r.r)) {
                pos += r.len;
                continue;
            }
        }
        break;
    }
    return .{ .int = @intCast(pos) };
}

/// rune_len_at(s, pos): byte length of the character at pos, or 0 at the end.
fn strRuneLenAt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const pos = api.argIntOr(args, 1, 0);
    if (pos < 0 or pos >= s.len) return .{ .int = 0 };
    return .{ .int = @intCast(decodeRune(s, @intCast(pos)).len) };
}

/// hash(s): a stable 64-bit hash of s as hex digits (FNV-1a).
fn strHash(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var buf: [16]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{x}", .{std.hash.Fnv1a_64.hash(s)}) catch unreachable;
    return th.vm.str(out);
}

/// compare(a, b): -1, 0 or 1 (byte-wise).
fn strCompare(th: *Thread, args: []Value) Error!Value {
    const a = try api.argString(th, args, 0, "a");
    const b = try api.argString(th, args, 1, "b");
    return .{ .int = switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } };
}

/// from_bytes(list) -> string: a string from a table of byte values (0-255).
fn strFromBytes(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "bytes");
    const n = t.len();
    const out = th.vm.newStringUninit(n);
    const buf = out.mutableBytes();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = t.getInt(@intCast(i));
        if (v != .int or v.int < 0 or v.int > 255) {
            const shown = vm_mod.format.valueToOwned(th.vm.gpa, v);
            defer th.vm.gpa.free(shown);
            return th.vm.raise("from_bytes: element {d} is not a byte value: {s}", .{ i, shown });
        }
        buf[i] = @intCast(v.int);
    }
    return .{ .string = out };
}
