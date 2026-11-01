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
        // pieces
        .{ .name = "substring", .f = strSubstring },
        .{ .name = "byte_at", .f = strByteAt },
        .{ .name = "char_at", .f = strCharAt },
        .{ .name = "from_bytes", .f = strFromBytes },
        .{ .name = "to_bytes", .f = strToBytes },
        // searching
        .{ .name = "index_of", .f = strIndexOf },
        .{ .name = "last_index_of", .f = strLastIndexOf },
        .{ .name = "contains", .f = strContains },
        .{ .name = "count", .f = strCount },
        .{ .name = "starts_with", .f = strStartsWith },
        .{ .name = "ends_with", .f = strEndsWith },
        .{ .name = "compare", .f = strCompare },
        .{ .name = "equal_fold", .f = strEqualFold },
        // splitting and joining
        .{ .name = "join", .f = strJoin },
        .{ .name = "split", .f = strSplit },
        .{ .name = "cut", .f = strCut },
        .{ .name = "fields", .f = strFields },
        .{ .name = "lines", .f = strLines },
        // transforming
        .{ .name = "trim", .f = strTrim },
        .{ .name = "trim_start", .f = strTrimStart },
        .{ .name = "trim_end", .f = strTrimEnd },
        .{ .name = "trim_prefix", .f = strTrimPrefix },
        .{ .name = "trim_suffix", .f = strTrimSuffix },
        .{ .name = "upper", .f = strUpper },
        .{ .name = "lower", .f = strLower },
        .{ .name = "replace", .f = strReplace },
        .{ .name = "xor", .f = strXor },
        // numbers and formatting
        .{ .name = "format", .f = strFormat },
        .{ .name = "to_number", .f = strToNumber },
        .{ .name = "parse_int", .f = strParseInt },
        // lines and columns
        .{ .name = "line_starts", .f = strLineStarts },
        .{ .name = "line_col", .f = strLineCol },
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
pub fn isUnicodeSpace(r: u21) bool {
    return switch (r) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85, 0xA0 => true,
        0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
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

/// last_index_of(s, sub, [from]): byte index of the last sub that starts
/// at or before from (the end by default), or -1.
fn strLastIndexOf(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const sub = try api.argString(th, args, 1, "sub");
    const from = api.argIntOr(args, 2, @intCast(s.len));
    if (from < 0) return .{ .int = -1 };
    const limit = @min(s.len, @as(usize, @intCast(from)) + sub.len);
    const i = std.mem.lastIndexOf(u8, s[0..limit], sub) orelse return .{ .int = -1 };
    return .{ .int = @intCast(i) };
}

fn strContains(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const sub = try api.argString(th, args, 1, "sub");
    return .{ .bool = std.mem.indexOf(u8, s, sub) != null };
}

/// count(s, sub): the number of non-overlapping subs in s; an empty sub
/// counts the characters plus one (Go's strings.Count).
fn strCount(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const sub = try api.argString(th, args, 1, "sub");
    if (sub.len == 0) {
        var n: i64 = 1;
        for (s) |b| {
            if (b & 0xC0 != 0x80) n += 1;
        }
        return .{ .int = n };
    }
    var n: i64 = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, s, pos, sub)) |i| {
        n += 1;
        pos = i + sub.len;
    }
    return .{ .int = n };
}

fn strEqualFold(th: *Thread, args: []Value) Error!Value {
    const a = try api.argString(th, args, 0, "a");
    const b = try api.argString(th, args, 1, "b");
    return .{ .bool = std.ascii.eqlIgnoreCase(a, b) };
}

/// to_bytes(s): the bytes of s as a list of ints.
fn strToBytes(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const t = th.vm.newTable(s.len, 0);
    for (s) |b| t.append(th.vm.gpa, .{ .int = b });
    return .{ .table = t };
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

/// split(s, sep, [n]): the parts between the seps; n > 0 keeps at most n
/// parts (the last is the rest of s), n == 0 none, n < 0 (the default) all.
fn strSplit(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const s = try api.argString(th, args, 0, "str");
    const sep = try api.argString(th, args, 1, "sep");
    const n = api.argIntOr(args, 2, -1);
    const t = vm.newTable(0, 0);
    if (n == 0) return .{ .table = t };
    var parts: i64 = 0;
    var pos: usize = 0;
    if (sep.len == 0) {
        // Go splits into UTF-8 characters
        while (pos < s.len) {
            if (n > 0 and parts == n - 1) break;
            const r = decodeRune(s, pos);
            t.append(vm.gpa, vm.str(s[pos .. pos + r.len]));
            pos += r.len;
            parts += 1;
        }
        if (pos < s.len) t.append(vm.gpa, vm.str(s[pos..]));
        return .{ .table = t };
    }
    while (true) {
        if (n > 0 and parts == n - 1) break;
        const i = std.mem.indexOfPos(u8, s, pos, sep) orelse break;
        t.append(vm.gpa, vm.str(s[pos..i]));
        pos = i + sep.len;
        parts += 1;
    }
    t.append(vm.gpa, vm.str(s[pos..]));
    return .{ .table = t };
}

/// cut(s, sep): {before, after} around the first sep, or null.
fn strCut(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const s = try api.argString(th, args, 0, "str");
    const sep = try api.argString(th, args, 1, "sep");
    const i = std.mem.indexOf(u8, s, sep) orelse return .null;
    const t = vm.newTable(2, 0);
    t.append(vm.gpa, vm.str(s[0..i]));
    t.append(vm.gpa, vm.str(s[i + sep.len ..]));
    return .{ .table = t };
}

/// fields(s): the parts of s between runs of whitespace.
fn strFields(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const s = try api.argString(th, args, 0, "str");
    const t = vm.newTable(0, 0);
    var pos: usize = 0;
    var start: ?usize = null;
    while (pos < s.len) {
        const r = decodeRune(s, pos);
        if (isUnicodeSpace(r.r)) {
            if (start) |st| t.append(vm.gpa, vm.str(s[st..pos]));
            start = null;
        } else if (start == null) {
            start = pos;
        }
        pos += r.len;
    }
    if (start) |st| t.append(vm.gpa, vm.str(s[st..]));
    return .{ .table = t };
}

/// lines(s): the lines of s without their line endings ("\n" or "\r\n");
/// a final line ending does not start another line.
fn strLines(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const s = try api.argString(th, args, 0, "str");
    const t = vm.newTable(0, 0);
    var pos: usize = 0;
    while (pos < s.len) {
        const nl = std.mem.indexOfScalarPos(u8, s, pos, '\n') orelse s.len;
        var end = nl;
        if (end > pos and s[end - 1] == '\r') end -= 1;
        t.append(vm.gpa, vm.str(s[pos..end]));
        pos = nl + 1;
    }
    return .{ .table = t };
}

/// Whether r is trimmed: in the cutset, or whitespace without one.
fn trimmed(r: u21, cutset: ?[]const u8) bool {
    const set = cutset orelse return isUnicodeSpace(r);
    var i: usize = 0;
    while (i < set.len) {
        const c = decodeRune(set, i);
        if (c.r == r) return true;
        i += c.len;
    }
    return false;
}

fn trimRange(s: []const u8, cutset: ?[]const u8, front: bool, back: bool) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    if (front) while (start < end) {
        const r = decodeRune(s, start);
        if (!trimmed(r.r, cutset)) break;
        start += r.len;
    };
    if (back) while (end > start) {
        // walk back to the start of the last character
        var p = end - 1;
        while (p > start and (s[p] & 0xC0) == 0x80) p -= 1;
        const r = decodeRune(s, p);
        if (!trimmed(r.r, cutset)) break;
        end = p;
    };
    return s[start..end];
}

fn trimWith(th: *Thread, args: []Value, front: bool, back: bool) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const cutset: ?[]const u8 = if (api.arg(args, 1) == .null) null else try api.argString(th, args, 1, "cutset");
    return th.vm.str(trimRange(s, cutset, front, back));
}

/// trim(s, [cutset]): s without leading and trailing whitespace, or
/// characters of cutset.
fn strTrim(th: *Thread, args: []Value) Error!Value {
    return trimWith(th, args, true, true);
}

fn strTrimStart(th: *Thread, args: []Value) Error!Value {
    return trimWith(th, args, true, false);
}

fn strTrimEnd(th: *Thread, args: []Value) Error!Value {
    return trimWith(th, args, false, true);
}

fn strTrimPrefix(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const prefix = try api.argString(th, args, 1, "prefix");
    if (!std.mem.startsWith(u8, s, prefix)) return api.arg(args, 0);
    return th.vm.str(s[prefix.len..]);
}

fn strTrimSuffix(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const suffix = try api.argString(th, args, 1, "suffix");
    if (!std.mem.endsWith(u8, s, suffix)) return api.arg(args, 0);
    return th.vm.str(s[0 .. s.len - suffix.len]);
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

/// replace(s, old, new, [n]): s with the first n olds (all when n is left
/// out or negative) replaced by new.
fn strReplace(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const old = try api.argString(th, args, 1, "old");
    const repl = try api.argString(th, args, 2, "new");
    const n = api.argIntOr(args, 3, -1);
    if (old.len == 0 or n == 0) return api.arg(args, 0);
    if (n < 0) {
        const out = std.mem.replaceOwned(u8, th.vm.gpa, s, old, repl) catch oom();
        defer th.vm.gpa.free(out);
        return th.vm.str(out);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(th.vm.gpa);
    var pos: usize = 0;
    var done: i64 = 0;
    while (done < n) : (done += 1) {
        const i = std.mem.indexOfPos(u8, s, pos, old) orelse break;
        out.appendSlice(th.vm.gpa, s[pos..i]) catch oom();
        out.appendSlice(th.vm.gpa, repl) catch oom();
        pos = i + old.len;
    }
    out.appendSlice(th.vm.gpa, s[pos..]) catch oom();
    return th.vm.str(out.items);
}

/// xor(data, key): data XOR key repeated (WebSocket masking; the same call
/// unmasks).
fn strXor(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "data");
    const key = try api.argString(th, args, 1, "key");
    if (key.len == 0) return th.vm.raise("xor: the key is empty", .{});
    const out = th.vm.newStringUninit(src.len);
    const bytes = out.mutableBytes();
    for (src, 0..) |b, i| bytes[i] = b ^ key[i % key.len];
    return .{ .string = out };
}

/// format(fmt, ...values): see strformat.zig.
fn strFormat(th: *Thread, args: []Value) Error!Value {
    const fmt = try api.argString(th, args, 0, "format");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(th.vm.gpa);
    try @import("strformat.zig").format(th, fmt, 1, &out);
    return th.vm.str(out.items);
}

/// parse_int(s, [base]): s as an int in base (10 by default, 2 to 36; 0
/// reads a 0x, 0o or 0b prefix), with an optional sign; null when s is not
/// one or does not fit.
fn strParseInt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var base = api.argIntOr(args, 1, 10);
    if (base != 0 and (base < 2 or base > 36)) return th.vm.raise("parse_int: base {d} is not 0 or 2 to 36", .{base});
    var body = s;
    var neg = false;
    if (body.len > 0 and (body[0] == '-' or body[0] == '+')) {
        neg = body[0] == '-';
        body = body[1..];
    }
    if (base == 0) {
        base = 10;
        if (body.len > 2 and body[0] == '0') {
            switch (body[1]) {
                'x', 'X' => base = 16,
                'o', 'O' => base = 8,
                'b', 'B' => base = 2,
                else => {},
            }
            if (base != 10) body = body[2..];
        }
    }
    if (body.len == 0) return .null;
    // accumulate negatively so that the minimum int parses
    var n: i64 = 0;
    for (body) |c| {
        const dgt = std.fmt.charToDigit(c, @intCast(base)) catch return .null;
        n = std.math.mul(i64, n, base) catch return .null;
        n = std.math.sub(i64, n, dgt) catch return .null;
    }
    if (neg) return .{ .int = n };
    if (n == std.math.minInt(i64)) return .null;
    return .{ .int = -n };
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
