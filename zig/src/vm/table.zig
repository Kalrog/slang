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

/// The slang table: an array part for keys 0..n-1 plus an insertion-ordered
/// hash part. The key "meta" addresses the metatable. Storing null removes
/// the key (and shifts the array part when the key is an array index).
pub const Table = struct {
    obj: Object,
    arr: std.ArrayList(Value) = .empty,
    ents: std.ArrayList(Entry) = .empty,
    index: Index = .empty,
    dead: u32 = 0,
    meta: ?*Table = null,

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
        if (t.index.get(.{ .string = s })) |idx| return t.ents.items[idx].val;
        if (s.eqlBytes("meta")) return Value.fromTable(t.meta);
        return .null;
    }

    /// Lookup of a string key given as bytes (for natives).
    pub fn getName(t: *const Table, name: []const u8) Value {
        if (t.index.getAdapted(name, BytesCtx{})) |idx| return t.ents.items[idx].val;
        if (std.mem.eql(u8, name, "meta")) return Value.fromTable(t.meta);
        return .null;
    }

    pub fn getInt(t: *const Table, i: i64) Value {
        if (i >= 0 and i < t.arr.items.len) return t.arr.items[@intCast(i)];
        return t.anyGet(.{ .int = i });
    }

    fn anyGet(t: *const Table, key: Value) Value {
        if (t.index.get(key)) |idx| return t.ents.items[idx].val;
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
        if (s.eqlBytes("meta")) {
            t.meta = val.asTable();
            return;
        }
        t.setAny(gpa, .{ .string = s }, val);
    }

    fn setAny(t: *Table, gpa: Allocator, key: Value, val: Value) void {
        const gop = t.index.getOrPut(gpa, key) catch oom();
        if (gop.found_existing) {
            t.ents.items[gop.value_ptr.*].val = val;
            return;
        }
        gop.value_ptr.* = @intCast(t.ents.items.len);
        t.ents.append(gpa, .{ .key = key, .val = val }) catch oom();
    }

    /// Migrates hash entries whose integer key continues the array part.
    fn fixList(t: *Table, gpa: Allocator) void {
        while (true) {
            const k: Value = .{ .int = @intCast(t.arr.items.len) };
            const kv = t.index.fetchRemove(k) orelse return;
            const v = t.ents.items[kv.value].val;
            t.killEntry(gpa, kv.value);
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
        t.index.clearRetainingCapacity();
        for (t.ents.items, 0..) |e, i| {
            t.index.put(gpa, e.key, @intCast(i)) catch oom();
        }
    }

    /// Deletes a key and returns the removed value (null if absent).
    pub fn remove(t: *Table, gpa: Allocator, key: Value) Value {
        switch (key) {
            .int => |i| {
                if (i >= 0 and i < t.arr.items.len) {
                    return t.arr.orderedRemove(@intCast(i));
                }
                return t.removeAny(gpa, key);
            },
            .string => |s| {
                if (t.index.fetchRemove(key)) |kv| {
                    const v = t.ents.items[kv.value].val;
                    t.killEntry(gpa, kv.value);
                    return v;
                }
                if (s.eqlBytes("meta")) {
                    const m = t.meta;
                    t.meta = null;
                    return Value.fromTable(m);
                }
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
        if (t.index.fetchRemove(key)) |kv| {
            const v = t.ents.items[kv.value].val;
            t.killEntry(gpa, kv.value);
            return v;
        }
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
                const idx = t.index.get(key) orelse return null;
                start = t.arr.items.len + idx + 1;
            },
            else => {
                const idx = t.index.get(normKey(key)) orelse return null;
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
    // removing from the array part shifts
    _ = t.remove(gpa, .{ .int = 0 });
    try std.testing.expectEqual(@as(i64, 11), t.getInt(0).int);
    try std.testing.expectEqual(@as(usize, 5), t.len());
    // float keys normalise
    try std.testing.expectEqual(@as(i64, 12), t.get(.{ .float = 1.0 }).int);
}
