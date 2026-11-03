const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const String = @import("string.zig").String;
const Object = @import("object.zig").Object;
const oom = @import("../vm.zig").oom;

pub const Entry = struct {
    key: Value,
    val: Value,
};

const KeyCtx = struct {
    pub fn hash(_: KeyCtx, k: Value) u64 {
        return k.keyHash();
    }
    pub fn eql(_: KeyCtx, a: Value, b: Value) bool {
        return a.keyEql(b);
    }
};

/// Lookup of string keys by their bytes, without creating a String.
const BytesCtx = struct {
    pub fn hash(_: BytesCtx, k: []const u8) u64 {
        return String.hashBytes(k);
    }
    pub fn eql(_: BytesCtx, a: []const u8, b: Value) bool {
        return switch (b) {
            .string => |s| s.eqlBytes(a),
            else => false,
        };
    }
};

const Index = std.HashMapUnmanaged(Value, u32, KeyCtx, 80);

/// Hash parts up to this many entries are searched linearly; the index is
/// built when a table outgrows it (most tables are small records whose keys
/// are interned strings, where a pointer comparison per entry beats hashing).
const small_limit = 8;

/// The slang table: an array part for keys 0..n-1 plus an insertion-ordered
/// hash part. The metatable is not a key (slang's x.@meta reads it).
/// Storing null removes the key and nothing else: the elements after a
/// removed list index keep their keys (they move to the hash part, and
/// back once the gap is filled). Only removeShifting (the global remove)
/// moves list elements down.

/// Which references a weak table (slang/vm's weak_keys, weak_values) does
/// not keep alive: an entry goes once its key (an ephemeron: its value only
/// stays alive through the key) or its value is collected. Strings, numbers
/// and booleans are values, never collected out of a weak table.
pub const Weak = enum(u8) { none, keys, values };

pub const Table = struct {
    obj: Object,
    arr: std.ArrayList(Value) = .empty,
    ents: std.ArrayList(Entry) = .empty,
    index: Index = .empty,
    indexed: bool = false,
    /// what this table has as a metatable (see metaFlags); 0 is unknown
    mflags: u8 = 0,
    weak: Weak = .none,
    dead: u32 = 0,
    meta: ?*Table = null,

    const mf_valid: u8 = 1;
    pub const mf_newindex: u8 = 2;
    pub const mf_get: u8 = 4;
    pub const mf_set: u8 = 8;

    /// What this table, used as a metatable, has of __newindex, __get and
    /// __set (the VM's interned names), as mf_ bits. Cached until a key is
    /// added to or removed from the table.
    pub inline fn metaFlags(m: *Table, newindex: *String, getter: *String, setter: *String) u8 {
        if (m.mflags & mf_valid == 0) {
            var f: u8 = mf_valid;
            if (m.find(.{ .string = newindex }) != null) f |= mf_newindex;
            if (m.find(.{ .string = getter }) != null) f |= mf_get;
            if (m.find(.{ .string = setter }) != null) f |= mf_set;
            m.mflags = f;
        }
        return m.mflags;
    }

    pub fn init(gpa: Allocator, narr: usize, nhash: usize) Table {
        var t: Table = .{ .obj = .{ .kind = .table } };
        if (narr > 0) t.arr.ensureTotalCapacity(gpa, narr) catch oom();
        if (nhash > 0) t.ents.ensureTotalCapacity(gpa, nhash) catch oom();
        return t;
    }

    pub fn deinit(t: *Table, gpa: Allocator) void {
        t.arr.deinit(gpa);
        t.ents.deinit(gpa);
        t.index.deinit(gpa);
    }

    fn normKey(k: Value) Value {
        if (k == .float) {
            const f = k.float;
            if (f == @trunc(f) and f >= -9.2e18 and f <= 9.2e18) return .{ .int = @intFromFloat(f) };
        }
        return k;
    }

    /// Raw lookup (no metamethods).
    pub fn get(t: *const Table, key: Value) Value {
        switch (key) {
            .int => |i| {
                if (i >= 0 and i < t.arr.items.len) return t.arr.items[@intCast(i)];
                return t.anyGet(key);
            },
            .string => |s| return t.getStr(s),
            .float => {
                const k = normKey(key);
                if (k == .int) return t.get(k);
                return t.anyGet(k);
            },
            .null => return .null,
            else => return t.anyGet(key),
        }
    }

    pub fn getStr(t: *const Table, s: *String) Value {
        if (t.find(.{ .string = s })) |idx| return t.ents.items[idx].val;
        return .null;
    }

    /// Lookup of a string key given as bytes (for natives).
    pub fn getName(t: *const Table, name: []const u8) Value {
        if (t.findBytes(name)) |idx| return t.ents.items[idx].val;
        return .null;
    }

    /// The position of key in the hash part.
    fn find(t: *const Table, key: Value) ?u32 {
        if (t.indexed) return t.index.get(key);
        for (t.ents.items, 0..) |e, i| {
            if (e.key.keyEql(key)) return @intCast(i);
        }
        return null;
    }

    fn findBytes(t: *const Table, name: []const u8) ?u32 {
        if (t.indexed) return t.index.getAdapted(name, BytesCtx{});
        for (t.ents.items, 0..) |e, i| {
            if (e.key == .string and e.key.string.eqlBytes(name)) return @intCast(i);
        }
        return null;
    }

    fn buildIndex(t: *Table, gpa: Allocator) void {
        t.index.clearRetainingCapacity();
        t.index.ensureTotalCapacity(gpa, @intCast(t.ents.items.len * 2)) catch oom();
        for (t.ents.items, 0..) |e, i| {
            if (e.key != .null) t.index.putAssumeCapacity(e.key, @intCast(i));
        }
        t.indexed = true;
    }

    /// Removes the entry at idx (found by find) and returns its value.
    fn takeEntry(t: *Table, gpa: Allocator, idx: u32) Value {
        t.mflags = 0;
        const e = t.ents.items[idx];
        if (t.indexed) _ = t.index.remove(e.key);
        t.killEntry(gpa, idx);
        return e.val;
    }

    pub fn getInt(t: *const Table, i: i64) Value {
        if (i >= 0 and i < t.arr.items.len) return t.arr.items[@intCast(i)];
        return t.anyGet(.{ .int = i });
    }

    fn anyGet(t: *const Table, key: Value) Value {
        if (t.find(key)) |idx| return t.ents.items[idx].val;
        return .null;
    }

    /// Raw store. Storing null removes the key.
    pub fn set(t: *Table, gpa: Allocator, key: Value, val: Value) void {
        if (val == .null) {
            _ = t.remove(gpa, key);
            return;
        }
        switch (key) {
            .int => |i| t.setInt(gpa, i, val),
            .string => |s| t.setStr(gpa, s, val),
            .float => {
                const k = normKey(key);
                if (k == .int) t.setInt(gpa, k.int, val) else t.setAny(gpa, k, val);
            },
            .null => return,
            else => t.setAny(gpa, key, val),
        }
    }

    fn setInt(t: *Table, gpa: Allocator, i: i64, val: Value) void {
        const n: i64 = @intCast(t.arr.items.len);
        if (i >= 0 and i < n) {
            t.arr.items[@intCast(i)] = val;
        } else if (i == n) {
            t.arr.append(gpa, val) catch oom();
            t.fixList(gpa);
        } else {
            t.setAny(gpa, .{ .int = i }, val);
        }
    }

    pub fn setStr(t: *Table, gpa: Allocator, s: *String, val: Value) void {
        if (val == .null) {
            _ = t.remove(gpa, .{ .string = s });
            return;
        }
        t.setAny(gpa, .{ .string = s }, val);
    }

    /// Overwrites the value of an existing string key; false when the key
    /// is absent (or the value is null, which changes the key set).
    pub fn replaceStr(t: *Table, s: *String, val: Value) bool {
        if (val == .null) return false;
        const idx = t.find(.{ .string = s }) orelse return false;
        t.ents.items[idx].val = val;
        return true;
    }

    /// Stores under a string key that is known to be absent a value that
    /// is not null: what filling a fresh table does.
    pub fn addFresh(t: *Table, gpa: Allocator, s: *String, val: Value) void {
        t.insertNew(gpa, .{ .string = s }, val);
    }

    fn setAny(t: *Table, gpa: Allocator, key: Value, val: Value) void {
        if (t.find(key)) |idx| {
            t.ents.items[idx].val = val;
            return;
        }
        t.insertNew(gpa, key, val);
    }

    /// Adds an entry for a key that is not in the hash part.
    fn insertNew(t: *Table, gpa: Allocator, key: Value, val: Value) void {
        t.mflags = 0;
        const idx: u32 = @intCast(t.ents.items.len);
        t.ents.append(gpa, .{ .key = key, .val = val }) catch oom();
        if (t.indexed) {
            t.index.put(gpa, key, idx) catch oom();
        } else if (t.ents.items.len > small_limit) {
            t.buildIndex(gpa);
        }
    }

    /// Migrates hash entries whose integer key continues the array part.
    fn fixList(t: *Table, gpa: Allocator) void {
        if (t.ents.items.len == t.dead) return;
        while (true) {
            const k: Value = .{ .int = @intCast(t.arr.items.len) };
            const idx = t.find(k) orelse return;
            const v = t.takeEntry(gpa, idx);
            t.arr.append(gpa, v) catch oom();
        }
    }

    fn killEntry(t: *Table, gpa: Allocator, idx: u32) void {
        t.ents.items[idx] = .{ .key = .null, .val = .null };
        t.dead += 1;
        if (t.dead > 8 and t.dead > t.ents.items.len / 2) t.compact(gpa);
    }

    fn compact(t: *Table, gpa: Allocator) void {
        var w: usize = 0;
        for (t.ents.items) |e| {
            if (e.key != .null) {
                t.ents.items[w] = e;
                w += 1;
            }
        }
        t.ents.shrinkRetainingCapacity(w);
        t.dead = 0;
        if (t.indexed) {
            if (w > small_limit) {
                t.buildIndex(gpa);
            } else {
                t.index.clearRetainingCapacity();
                t.indexed = false;
            }
        }
    }

    /// Takes the element at list index i out of the array part, moving
    /// the later ones down (the global remove); null when i is not an
    /// index of the array part.
    pub fn removeShifting(t: *Table, i: i64) ?Value {
        if (i < 0 or i >= t.arr.items.len) return null;
        return t.arr.orderedRemove(@intCast(i));
    }

    /// Deletes a key and returns the removed value (null if absent). Only
    /// that key goes: removing a list index in the middle moves the
    /// elements after it to the hash part under their own keys.
    pub fn remove(t: *Table, gpa: Allocator, key: Value) Value {
        switch (key) {
            .int => |i| {
                if (i >= 0 and i < t.arr.items.len) {
                    const at: usize = @intCast(i);
                    const v = t.arr.items[at];
                    for (t.arr.items[at + 1 ..], at + 1..) |x, k| t.insertNew(gpa, .{ .int = @intCast(k) }, x);
                    t.arr.shrinkRetainingCapacity(at);
                    return v;
                }
                return t.removeAny(gpa, key);
            },
            .string => {
                if (t.find(key)) |idx| return t.takeEntry(gpa, idx);
                return .null;
            },
            .float => {
                const k = normKey(key);
                if (k == .int) return t.remove(gpa, k);
                return t.removeAny(gpa, k);
            },
            .null => return .null,
            else => return t.removeAny(gpa, key),
        }
    }

    fn removeAny(t: *Table, gpa: Allocator, key: Value) Value {
        if (t.find(key)) |idx| return t.takeEntry(gpa, idx);
        return .null;
    }

    /// Number of entries (array part plus hash part).
    pub fn len(t: *const Table) usize {
        return t.arr.items.len + t.ents.items.len - t.dead;
    }

    pub fn arrayLen(t: *const Table) usize {
        return t.arr.items.len;
    }

    /// Adds a value at the end of the array part (null is ignored).
    pub fn append(t: *Table, gpa: Allocator, v: Value) void {
        if (v == .null) return;
        t.arr.append(gpa, v) catch oom();
        t.fixList(gpa);
    }

    /// Appends v to the array part even when it is null (sequence results of
    /// the parser library need positional null entries).
    pub fn pushSlot(t: *Table, gpa: Allocator, v: Value) void {
        t.arr.append(gpa, v) catch oom();
        t.fixList(gpa);
    }

    /// Merges another table: array parts are concatenated, hash entries copied.
    pub fn addAll(t: *Table, gpa: Allocator, o: *const Table) void {
        t.arr.appendSlice(gpa, o.arr.items) catch oom();
        for (o.ents.items) |e| {
            if (e.key == .null) continue;
            t.set(gpa, e.key, e.val);
        }
        t.fixList(gpa);
    }

    /// Iterates array indices and then hash entries in insertion order.
    pub const Iterator = struct {
        t: *const Table,
        i: usize = 0,

        pub fn next(it: *Iterator) ?Entry {
            const t = it.t;
            if (it.i < t.arr.items.len) {
                const i = it.i;
                it.i += 1;
                return .{ .key = .{ .int = @intCast(i) }, .val = t.arr.items[i] };
            }
            while (it.i - t.arr.items.len < t.ents.items.len) {
                const e = t.ents.items[it.i - t.arr.items.len];
                it.i += 1;
                if (e.key != .null) return e;
            }
            return null;
        }
    };

    pub fn iterator(t: *const Table) Iterator {
        return .{ .t = t };
    }

    /// The entry following key in iteration order (null key: the first),
    /// or null at the end or for a key that is not in the table.
    pub fn nextEntry(t: *const Table, key: Value) ?Entry {
        var start: usize = 0;
        switch (key) {
            .null => {},
            .int => |i| if (i >= 0 and i < t.arr.items.len) {
                start = @intCast(i + 1);
            } else {
                const idx = t.find(key) orelse return null;
                start = t.arr.items.len + idx + 1;
            },
            else => {
                const idx = t.find(normKey(key)) orelse return null;
                start = t.arr.items.len + idx + 1;
            },
        }
        var it: Iterator = .{ .t = t, .i = start };
        return it.next();
    }

    /// Structural equality (metatables are not compared).
    pub fn equals(t: *const Table, o: *const Table) bool {
        if (t == o) return true;
        if (t.arr.items.len != o.arr.items.len or t.len() != o.len()) return false;
        for (t.arr.items, o.arr.items) |a, b| {
            if (!a.equals(b)) return false;
        }
        for (t.ents.items) |e| {
            if (e.key == .null) continue;
            if (!o.get(e.key).equals(e.val)) return false;
        }
        return true;
    }
};

test "array part and hash part" {
    const gpa = std.testing.allocator;
    var t = Table.init(gpa, 0, 0);
    defer t.deinit(gpa);
    t.set(gpa, .{ .int = 0 }, .{ .int = 10 });
    t.set(gpa, .{ .int = 1 }, .{ .int = 11 });
    t.set(gpa, .{ .int = 5 }, .{ .int = 15 });
    try std.testing.expectEqual(@as(usize, 2), t.arrayLen());
    try std.testing.expectEqual(@as(usize, 3), t.len());
    // filling the gap migrates 5 into the array part once 2..4 exist
    t.set(gpa, .{ .int = 2 }, .{ .int = 12 });
    t.set(gpa, .{ .int = 3 }, .{ .int = 13 });
    t.set(gpa, .{ .int = 4 }, .{ .int = 14 });
    try std.testing.expectEqual(@as(usize, 6), t.arrayLen());
    try std.testing.expectEqual(@as(i64, 15), t.getInt(5).int);
    // removing from the array part removes that key only
    _ = t.remove(gpa, .{ .int = 0 });
    try std.testing.expectEqual(Value.null, t.getInt(0));
    try std.testing.expectEqual(@as(i64, 11), t.getInt(1).int);
    try std.testing.expectEqual(@as(usize, 5), t.len());
    try std.testing.expectEqual(@as(usize, 0), t.arrayLen());
    // filling the gap makes it a list again
    t.set(gpa, .{ .int = 0 }, .{ .int = 10 });
    try std.testing.expectEqual(@as(usize, 6), t.arrayLen());
    // removing the last element shrinks the list; removeShifting shifts
    _ = t.remove(gpa, .{ .int = 5 });
    try std.testing.expectEqual(@as(usize, 5), t.arrayLen());
    try std.testing.expectEqual(@as(i64, 10), t.removeShifting(0).?.int);
    try std.testing.expectEqual(@as(i64, 11), t.getInt(0).int);
    try std.testing.expectEqual(@as(usize, 4), t.arrayLen());
    // float keys normalise
    try std.testing.expectEqual(@as(i64, 12), t.get(.{ .float = 1.0 }).int);
}
