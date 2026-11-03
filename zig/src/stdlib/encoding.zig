//! slang/encoding: the byte encodings web code needs, in native code, one
//! table per encoding (Go's encoding/base64, encoding/hex, net/url):
//!
//!   base64.encode(s)            base64.decode(s) -> string or null
//!   base64url.encode(s, pad)    base64url.decode(s) -> string or null
//!   hex.encode(s)               hex.decode(s) -> string or null
//!   url.encode(s)               url.decode(s) -> string or null
//!   form.encode(s)              form.decode(s) -> string or null
//!   query.encode(table)         query.decode(s) -> table
//!   binary.encode(value)        binary.decode(s) -> value (raises)
//!
//! Strings are byte strings, so every encoder takes any bytes. Decoders
//! return null on malformed input (untrusted input is the normal case).
//! base64.decode accepts its input with or without padding; base64url
//! leaves the padding off unless pad is true, and decodes either form.
//! url is percent-encoding of a URI component (RFC 3986: everything but
//! A-Z a-z 0-9 - . _ ~ is escaped); form is the same with a space as "+"
//! (application/x-www-form-urlencoded).
//!
//! binary is a compact byte form of slang data (null, booleans, numbers,
//! strings and tables of them) for files and the network: small ints take
//! one byte, a float that a 32-bit float holds exactly takes five, and a
//! table's metatable is left out. A value null is a fine result, so
//! binary.decode raises on malformed input instead of returning null.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

pub fn module(vm: *VM) *Table {
    const m = vm.newTable(0, 6);
    sub(vm, m, "base64", base64Encode, base64Decode);
    sub(vm, m, "base64url", base64urlEncode, base64urlDecode);
    sub(vm, m, "hex", hexEncode, hexDecode);
    sub(vm, m, "url", urlEncode, urlDecode);
    sub(vm, m, "form", formEncode, formDecode);
    sub(vm, m, "query", queryEncode, queryDecode);
    sub(vm, m, "binary", binaryEncode, binaryDecode);
    return m;
}

fn sub(vm: *VM, m: *Table, name: []const u8, enc: vm_mod.NativeFn, dec: vm_mod.NativeFn) void {
    const t = stdlib.makeModule(vm, &.{
        .{ .name = "encode", .f = enc },
        .{ .name = "decode", .f = dec },
    });
    m.set(vm.gpa, vm.str(name), .{ .table = t });
}

/// A fresh string of n bytes for the caller to fill.
fn uninit(vm: *VM, n: usize) struct { value: Value, bytes: []u8 } {
    const s = vm.newStringUninit(n);
    return .{ .value = .{ .string = s }, .bytes = s.mutableBytes() };
}

// ------------------------------------------------------------ base64

fn encodeWith(th: *Thread, args: []Value, codecs: std.base64.Codecs) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    const out = uninit(th.vm, codecs.Encoder.calcSize(src.len));
    _ = codecs.Encoder.encode(out.bytes, src);
    return out.value;
}

/// Decodes with or without "=" padding: the padding is checked, then
/// stripped, and the rest decoded unpadded.
fn decodeWith(th: *Thread, args: []Value, codecs: std.base64.Codecs) Error!Value {
    var src = try api.argString(th, args, 0, "str");
    if (src.len > 0 and src[src.len - 1] == '=') {
        if (src.len % 4 != 0) return .null;
        src = src[0 .. src.len - 1];
        if (src.len > 0 and src[src.len - 1] == '=') src = src[0 .. src.len - 1];
    }
    const n = codecs.Decoder.calcSizeForSlice(src) catch return .null;
    const out = uninit(th.vm, n);
    codecs.Decoder.decode(out.bytes, src) catch return .null;
    return out.value;
}

fn base64Encode(th: *Thread, args: []Value) Error!Value {
    return encodeWith(th, args, std.base64.standard);
}

fn base64Decode(th: *Thread, args: []Value) Error!Value {
    return decodeWith(th, args, std.base64.standard_no_pad);
}

fn base64urlEncode(th: *Thread, args: []Value) Error!Value {
    return encodeWith(th, args, if (api.argBool(args, 1, false)) std.base64.url_safe else std.base64.url_safe_no_pad);
}

fn base64urlDecode(th: *Thread, args: []Value) Error!Value {
    return decodeWith(th, args, std.base64.url_safe_no_pad);
}

// ------------------------------------------------------------ hex

const hex_digits = "0123456789abcdef";
const hex_upper = "0123456789ABCDEF";

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn hexEncode(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    const out = uninit(th.vm, src.len * 2);
    for (src, 0..) |b, i| {
        out.bytes[2 * i] = hex_digits[b >> 4];
        out.bytes[2 * i + 1] = hex_digits[b & 15];
    }
    return out.value;
}

fn hexDecode(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    if (src.len % 2 != 0) return .null;
    const out = uninit(th.vm, src.len / 2);
    for (out.bytes, 0..) |*b, i| {
        const hi = hexValue(src[2 * i]) orelse return .null;
        const lo = hexValue(src[2 * i + 1]) orelse return .null;
        b.* = hi << 4 | lo;
    }
    return out.value;
}

// ------------------------------------------------------------ percent-encoding

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn percentEncodedLen(src: []const u8, form: bool) usize {
    var n: usize = 0;
    for (src) |c| n += if (unreserved(c) or (form and c == ' ')) 1 else 3;
    return n;
}

fn percentEncodeInto(dest: []u8, src: []const u8, form: bool) usize {
    var j: usize = 0;
    for (src) |c| {
        if (unreserved(c)) {
            dest[j] = c;
            j += 1;
        } else if (form and c == ' ') {
            dest[j] = '+';
            j += 1;
        } else {
            dest[j] = '%';
            dest[j + 1] = hex_upper[c >> 4];
            dest[j + 2] = hex_upper[c & 15];
            j += 3;
        }
    }
    return j;
}

fn percentEncode(th: *Thread, args: []Value, form: bool) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    const out = uninit(th.vm, percentEncodedLen(src, form));
    _ = percentEncodeInto(out.bytes, src, form);
    return out.value;
}

/// The decoded length, or null when a "%" is not followed by two hex digits.
fn percentDecodedLen(src: []const u8) ?usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (n += 1) {
        if (src[i] == '%') {
            if (i + 2 >= src.len) return null;
            _ = hexValue(src[i + 1]) orelse return null;
            _ = hexValue(src[i + 2]) orelse return null;
            i += 3;
        } else i += 1;
    }
    return n;
}

fn percentDecodeInto(dest: []u8, src: []const u8, form: bool) void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < src.len) : (j += 1) {
        const c = src[i];
        if (c == '%') {
            dest[j] = hexValue(src[i + 1]).? << 4 | hexValue(src[i + 2]).?;
            i += 3;
        } else {
            dest[j] = if (form and c == '+') ' ' else c;
            i += 1;
        }
    }
}

fn percentDecodeValue(vm: *VM, src: []const u8, form: bool) ?Value {
    const n = percentDecodedLen(src) orelse return null;
    if (n == src.len and std.mem.indexOfScalar(u8, src, '+') == null) return vm.str(src);
    const out = uninit(vm, n);
    percentDecodeInto(out.bytes, src, form);
    return out.value;
}

fn percentDecode(th: *Thread, args: []Value, form: bool) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    return percentDecodeValue(th.vm, src, form) orelse .null;
}

fn urlEncode(th: *Thread, args: []Value) Error!Value {
    return percentEncode(th, args, false);
}

fn urlDecode(th: *Thread, args: []Value) Error!Value {
    return percentDecode(th, args, false);
}

fn formEncode(th: *Thread, args: []Value) Error!Value {
    return percentEncode(th, args, true);
}

fn formDecode(th: *Thread, args: []Value) Error!Value {
    return percentDecode(th, args, true);
}

// ------------------------------------------------------------ query strings

/// query_decode(s) -> table: "a=1&b=x+y%21&flag" gives {a: "1", b: "x y!",
/// flag: ""}. A leading "?" is skipped; a repeated key keeps its last value;
/// a pair that does not decode is skipped. null decodes to {}.
fn queryDecode(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = vm.newTable(0, 0);
    var src = api.argStringOr(args, 0, "");
    if (src.len > 0 and src[0] == '?') src = src[1..];
    var it = std.mem.splitScalar(u8, src, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (eq) |e| pair[0..e] else pair;
        const raw_val = if (eq) |e| pair[e + 1 ..] else "";
        if (raw_key.len == 0) continue;
        const key = percentDecodeValue(vm, raw_key, true) orelse continue;
        const val = percentDecodeValue(vm, raw_val, true) orelse continue;
        t.set(vm.gpa, key, val);
    }
    return .{ .table = t };
}

/// query_encode(table) -> "a=1&b=x+y%21": the string, number and boolean
/// fields of the table, in key order so the result is stable; a list value
/// repeats its key once per element; null, false and other values are left
/// out.
fn queryEncode(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try api.argTable(th, args, 0, "table");
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(vm.gpa);
    var it = t.iterator();
    while (it.next()) |e| {
        if (e.key.asBytes()) |k| keys.append(vm.gpa, k) catch vm_mod.oom();
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    for (keys.items) |k| {
        const v = t.getName(k);
        if (v.asTable()) |list| {
            var i: usize = 0;
            while (i < list.arrayLen()) : (i += 1) try appendPair(th, &out, k, list.getInt(@intCast(i)));
        } else try appendPair(th, &out, k, v);
    }
    return vm.str(out.items);
}

fn appendPair(th: *Thread, out: *std.ArrayList(u8), key: []const u8, v: Value) Error!void {
    const gpa = th.vm.gpa;
    var buf: [64]u8 = undefined;
    const text: []const u8 = switch (v) {
        .string => v.asBytes().?,
        .int => |n| std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable,
        .float => |f| std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable,
        .bool => |b| if (b) "true" else return,
        else => return,
    };
    if (out.items.len > 0) out.append(gpa, '&') catch vm_mod.oom();
    appendEncoded(gpa, out, key);
    out.append(gpa, '=') catch vm_mod.oom();
    appendEncoded(gpa, out, text);
}

fn appendEncoded(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) void {
    const n = percentEncodedLen(s, true);
    const dest = out.addManyAsSlice(gpa, n) catch vm_mod.oom();
    _ = percentEncodeInto(dest, s, true);
}

// ------------------------------------------------------------ binary

/// A value is one tag byte and its payload:
///
///   0 null, 1 false, 2 true, 3 int (zigzag varint), 4 f32, 5 f64 (little
///   endian), 6 string (varint length, bytes), 7 table (varint n, n list
///   elements, varint m, m key/value pairs); a tag from 32 up is the int
///   tag - 32 (0 to 223).
const BinTag = struct {
    const null_ = 0;
    const false_ = 1;
    const true_ = 2;
    const int = 3;
    const f32_ = 4;
    const f64_ = 5;
    const string = 6;
    const table = 7;
    const small = 32;
};

/// Tables nested deeper than this are not encoded (and not decoded: the
/// decoder recurses too, on input from anywhere).
const binary_depth = 64;

const BinEncoder = struct {
    th: *Thread,
    out: std.ArrayList(u8) = .empty,

    fn byte(e: *BinEncoder, b: u8) void {
        e.out.append(e.th.vm.gpa, b) catch vm_mod.oom();
    }

    fn varint(e: *BinEncoder, n: u64) void {
        var x = n;
        while (x >= 0x80) : (x >>= 7) e.byte(@as(u8, @truncate(x)) | 0x80);
        e.byte(@truncate(x));
    }

    fn bytes(e: *BinEncoder, b: []const u8) void {
        e.out.appendSlice(e.th.vm.gpa, b) catch vm_mod.oom();
    }

    fn value(e: *BinEncoder, v: Value, depth: u32) Error!void {
        switch (v) {
            .null => e.byte(BinTag.null_),
            .bool => |b| e.byte(if (b) BinTag.true_ else BinTag.false_),
            .int => |i| {
                if (i >= 0 and i < 256 - BinTag.small) {
                    e.byte(@intCast(i + BinTag.small));
                } else {
                    e.byte(BinTag.int);
                    e.varint(@bitCast((i << 1) ^ (i >> 63)));
                }
            },
            .float => |f| {
                const narrow: f32 = @floatCast(f);
                if (@as(f64, narrow) == f or std.math.isNan(f)) {
                    e.byte(BinTag.f32_);
                    var b: [4]u8 = undefined;
                    std.mem.writeInt(u32, &b, @bitCast(narrow), .little);
                    e.bytes(&b);
                } else {
                    e.byte(BinTag.f64_);
                    var b: [8]u8 = undefined;
                    std.mem.writeInt(u64, &b, @bitCast(f), .little);
                    e.bytes(&b);
                }
            },
            .string => |s| {
                e.byte(BinTag.string);
                e.varint(s.bytes().len);
                e.bytes(s.bytes());
            },
            .table => |t| {
                if (depth >= binary_depth) return e.th.vm.raise("encoding: cannot encode a table nested deeper than {d} levels", .{binary_depth});
                e.byte(BinTag.table);
                e.varint(t.arr.items.len);
                for (t.arr.items) |x| try e.value(x, depth + 1);
                var n: u64 = 0;
                for (t.ents.items) |en| {
                    if (en.key != .null and en.val != .null) n += 1;
                }
                e.varint(n);
                for (t.ents.items) |en| {
                    if (en.key == .null or en.val == .null) continue;
                    try e.value(en.key, depth + 1);
                    try e.value(en.val, depth + 1);
                }
            },
            else => return e.th.vm.raise("encoding: cannot encode a {s} in binary", .{v.typeName()}),
        }
    }
};

/// binary.encode(value) -> string: value (null, booleans, numbers, strings
/// and tables of them) in the binary form; raises for anything else.
fn binaryEncode(th: *Thread, args: []Value) Error!Value {
    var e: BinEncoder = .{ .th = th };
    defer e.out.deinit(th.vm.gpa);
    try e.value(api.arg(args, 0), 0);
    return th.vm.str(e.out.items);
}

const BinDecoder = struct {
    th: *Thread,
    src: []const u8,
    pos: usize = 0,

    fn malformed(d: *BinDecoder) Error {
        return d.th.vm.raise("encoding: malformed binary data at byte {d}", .{d.pos});
    }

    fn byte(d: *BinDecoder) Error!u8 {
        if (d.pos >= d.src.len) return d.malformed();
        d.pos += 1;
        return d.src[d.pos - 1];
    }

    fn take(d: *BinDecoder, n: u64) Error![]const u8 {
        if (n > d.src.len - d.pos) return d.malformed();
        const b = d.src[d.pos..][0..@intCast(n)];
        d.pos += @intCast(n);
        return b;
    }

    fn varint(d: *BinDecoder) Error!u64 {
        var n: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = try d.byte();
            if (shift > 63) return d.malformed();
            n |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b < 0x80) return n;
            shift += 7;
        }
    }

    /// A count of things that each take at least one byte: more than are
    /// left is malformed (and would allocate for nothing).
    fn count(d: *BinDecoder) Error!usize {
        const n = try d.varint();
        if (n > d.src.len - d.pos) return d.malformed();
        return @intCast(n);
    }

    fn value(d: *BinDecoder, depth: u32) Error!Value {
        const vm = d.th.vm;
        const tag = try d.byte();
        if (tag >= BinTag.small) return .{ .int = tag - BinTag.small };
        switch (tag) {
            BinTag.null_ => return .null,
            BinTag.false_ => return .{ .bool = false },
            BinTag.true_ => return .{ .bool = true },
            BinTag.int => {
                const z = try d.varint();
                return .{ .int = @bitCast((z >> 1) ^ (0 -% (z & 1))) };
            },
            BinTag.f32_ => {
                const b = try d.take(4);
                const f: f32 = @bitCast(std.mem.readInt(u32, b[0..4], .little));
                return .{ .float = f };
            },
            BinTag.f64_ => {
                const b = try d.take(8);
                return .{ .float = @bitCast(std.mem.readInt(u64, b[0..8], .little)) };
            },
            BinTag.string => return vm.str(try d.take(try d.count())),
            BinTag.table => {
                if (depth >= binary_depth) return d.malformed();
                const narr = try d.count();
                const t = vm.newTable(narr, 0);
                for (0..narr) |_| {
                    const x = try d.value(depth + 1);
                    // (lists hold no null)
                    if (x == .null) return d.malformed();
                    t.append(vm.gpa, x);
                }
                const nhash = try d.count();
                for (0..nhash) |_| {
                    const k = try d.value(depth + 1);
                    const x = try d.value(depth + 1);
                    if (k == .null or (k == .float and std.math.isNan(k.float))) return d.malformed();
                    t.set(vm.gpa, k, x);
                }
                return .{ .table = t };
            },
            else => return d.malformed(),
        }
    }
};

/// binary.decode(s) -> value: the value binary.encode made s from; raises
/// when s is not one whole value.
fn binaryDecode(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    var d: BinDecoder = .{ .th = th, .src = src };
    const v = try d.value(0);
    if (d.pos != src.len) return d.malformed();
    return v;
}
