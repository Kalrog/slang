//! slang/encoding: the byte encodings web code needs, in native code.
//!
//!   base64_encode(s)            base64_decode(s) -> string or null
//!   base64url_encode(s, pad)    base64url_decode(s) -> string or null
//!   hex_encode(s)               hex_decode(s) -> string or null
//!   url_encode(s)               url_decode(s) -> string or null
//!   form_encode(s)              form_decode(s) -> string or null
//!   query_encode(table)         query_decode(s) -> table
//!   utf8_valid(s) -> bool       crc32(s) -> int
//!   mask(data, key) -> data XOR the key repeated (WebSocket masking; the
//!     same call unmasks)
//!
//! Strings are byte strings, so every encoder takes any bytes. Decoders
//! return null on malformed input (untrusted input is the normal case).
//! base64_decode accepts its input with or without padding; base64url
//! leaves the padding off unless pad is true, and decodes either form.
//! url_* is percent-encoding of a URI component (RFC 3986: everything but
//! A-Z a-z 0-9 - . _ ~ is escaped); form_* is the same with a space as
//! "+" (application/x-www-form-urlencoded).

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
    return stdlib.makeModule(vm, &.{
        .{ .name = "base64_encode", .f = base64Encode },
        .{ .name = "base64_decode", .f = base64Decode },
        .{ .name = "base64url_encode", .f = base64urlEncode },
        .{ .name = "base64url_decode", .f = base64urlDecode },
        .{ .name = "hex_encode", .f = hexEncode },
        .{ .name = "hex_decode", .f = hexDecode },
        .{ .name = "url_encode", .f = urlEncode },
        .{ .name = "url_decode", .f = urlDecode },
        .{ .name = "form_encode", .f = formEncode },
        .{ .name = "form_decode", .f = formDecode },
        .{ .name = "query_encode", .f = queryEncode },
        .{ .name = "query_decode", .f = queryDecode },
        .{ .name = "utf8_valid", .f = utf8Valid },
        .{ .name = "crc32", .f = crc32 },
        .{ .name = "mask", .f = mask },
    });
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

// ------------------------------------------------------------ checks

fn utf8Valid(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    return .{ .bool = std.unicode.utf8ValidateSlice(src) };
}

fn crc32(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "str");
    return .{ .int = std.hash.Crc32.hash(src) };
}

fn mask(th: *Thread, args: []Value) Error!Value {
    const src = try api.argString(th, args, 0, "data");
    const key = try api.argString(th, args, 1, "key");
    if (key.len == 0) return th.vm.raise("mask: the key is empty", .{});
    const out = uninit(th.vm, src.len);
    for (src, 0..) |b, i| out.bytes[i] = b ^ key[i % key.len];
    return out.value;
}
