const std = @import("std");
const Object = @import("object.zig").Object;

/// An immutable byte string (UTF-8 by convention). The bytes follow the
/// header in the same allocation. Strings up to `intern_limit` bytes are
/// interned by the VM, so equal short strings are the same object.
pub const String = struct {
    obj: Object,
    len: usize,
    /// 0 means "not computed yet" (a real hash of 0 is simply recomputed).
    hash_cache: u64,
    interned: bool,

    pub const intern_limit = 40;

    pub fn bytes(s: *const String) []const u8 {
        const base: [*]const u8 = @ptrCast(s);
        return base[@sizeOf(String)..][0..s.len];
    }

    pub fn mutableBytes(s: *String) []u8 {
        const base: [*]u8 = @ptrCast(s);
        return base[@sizeOf(String)..][0..s.len];
    }

    pub fn allocSize(len: usize) usize {
        return @sizeOf(String) + len;
    }

    pub fn hash(s: *String) u64 {
        if (s.hash_cache == 0) s.hash_cache = hashBytes(s.bytes());
        return s.hash_cache;
    }

    pub fn hashBytes(b: []const u8) u64 {
        return std.hash.Wyhash.hash(0x51ab, b);
    }

    pub fn eql(a: *String, b: *String) bool {
        if (a == b) return true;
        if (a.interned and b.interned) return false;
        if (a.len != b.len) return false;
        return std.mem.eql(u8, a.bytes(), b.bytes());
    }

    pub fn eqlBytes(a: *const String, b: []const u8) bool {
        return std.mem.eql(u8, a.bytes(), b);
    }
};
