//! slang/utf8: the characters of UTF-8 strings. slang/string works on
//! bytes; this module decodes and encodes code points.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const decodeRune = @import("stringlib.zig").decodeRune;

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "valid", .f = utf8Valid },
        .{ .name = "count", .f = utf8Count },
        .{ .name = "char", .f = utf8Char },
        .{ .name = "code_at", .f = utf8CodeAt },
        .{ .name = "size_at", .f = utf8SizeAt },
        .{ .name = "utf16_len", .f = utf8Utf16Len },
    });
}

/// valid(s): whether s is valid UTF-8.
pub fn utf8Valid(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    return .{ .bool = std.unicode.utf8ValidateSlice(s) };
}

/// count(s): the number of characters; each invalid byte counts as one.
fn utf8Count(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var n: i64 = 0;
    var pos: usize = 0;
    while (pos < s.len) {
        pos += decodeRune(s, pos).len;
        n += 1;
    }
    return .{ .int = n };
}

/// char(code): the character with the given code point (U+FFFD for an
/// invalid one, as Go's string(rune)).
pub fn utf8Char(th: *Thread, args: []Value) Error!Value {
    const c = try api.argInt(th, args, 0, "code");
    if (c >= 0 and c < 128) return th.vm.str(&[_]u8{@intCast(c)});
    var buf: [4]u8 = undefined;
    const cp: u21 = if (c < 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF)) 0xFFFD else @intCast(c);
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    return th.vm.str(buf[0..n]);
}

/// code_at(s, [pos]): the code point at byte offset pos (U+FFFD for an
/// invalid sequence), or null out of range.
fn utf8CodeAt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const pos = api.argIntOr(args, 1, 0);
    if (pos < 0 or pos >= s.len) return .null;
    return .{ .int = decodeRune(s, @intCast(pos)).r };
}

/// size_at(s, [pos]): the byte length of the character at pos, or 0 at the
/// end.
pub fn utf8SizeAt(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const pos = api.argIntOr(args, 1, 0);
    if (pos < 0 or pos >= s.len) return .{ .int = 0 };
    return .{ .int = @intCast(decodeRune(s, @intCast(pos)).len) };
}

/// utf16_len(s): the number of UTF-16 code units (what LSP positions count
/// by default): one per code point, two above U+FFFF.
pub fn utf8Utf16Len(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var n: i64 = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
        if (b >= 0xF0) n += 1;
    }
    return .{ .int = n };
}
