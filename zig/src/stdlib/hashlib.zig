//! slang/hash: checksums and digests that need no OpenSSL (slang/crypto has
//! the rest).

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
        .{ .name = "crc32", .f = crc32 },
        stdlib.fast("fnv1a", fnv1a),
        .{ .name = "sha256", .f = sha256 },
    });
}

/// crc32(s): the CRC-32 (IEEE) checksum of s.
pub fn crc32(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    return .{ .int = std.hash.Crc32.hash(s) };
}

/// fnv1a(s): the 64-bit FNV-1a hash of s, as an int (format it with %x for
/// hex digits).
fn fnv1a(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    return .{ .int = @bitCast(std.hash.Fnv1a_64.hash(s)) };
}

/// sha256(s): the SHA-256 digest of s, 32 raw bytes.
pub fn sha256(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &out, .{});
    return th.vm.str(&out);
}
