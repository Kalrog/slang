const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

// What a callback may do: run slang code, which may collect, grow the stack
// (the args slice moves) or change the table. The values a native holds
// across a call are on the stack (`keep`), arguments are copied first, and
// tables are read by index again after every call.

/// slang/table: helpers over tables and lists.
pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "contains", .f = tContains },
        .{ .name = "map", .f = tMap },
        .{ .name = "filter", .f = tFilter },
        .{ .name = "fold", .f = tFold },
        .{ .name = "keys", .f = tKeys },
        .{ .name = "sort", .f = tSort },
        .{ .name = "insert", .f = tInsert },
        .{ .name = "index_of", .f = tIndexOf },
        stdlib.fast("reverse", tReverse),
        stdlib.fast("slice", tSlice),
    });
}

/// pushes v so that the collector sees it while slang code runs; the
/// caller pops it (th.top -= 1)
fn keep(th: *Thread, v: Value) Error!void {
    try th.ensure(th.top + 1);
    th.push(v);
}

/// the keys of t in iteration order (list indices, then the others)
fn keysOf(vm: *VM, t: *const Table) *Table {
    const out = vm.newTable(t.len(), 0);
    var it = t.iterator();
    while (it.next()) |e| out.pushSlot(vm.gpa, e.key);
    return out;
}

fn tContains(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    const value = api.arg(args, 1);
    var i: usize = 0;
    while (i < t.arr.items.len) : (i += 1) {
        if (try th.equal(t.arr.items[i], value)) return .{ .bool = true };
    }
    i = 0;
    while (i < t.ents.items.len) : (i += 1) {
        const e = t.ents.items[i];
        if (e.key == .null) continue; // a removed entry
        if (try th.equal(e.val, value)) return .{ .bool = true };
    }
    return .{ .bool = false };
}

const Each = enum { map, filter };

/// map and filter: a new table under the same keys
fn mapOrFilter(th: *Thread, args: []Value, comptime what: Each) Error!Value {
    const vm = th.vm;
    const t = try api.argTable(th, args, 0, "t");
    const f: Value = .{ .function = try api.argFunction(th, args, 1, "f") };
    const out = vm.newTable(0, 0);
    try keep(th, .{ .table = out });
    defer th.top -= 1;
    const ks = keysOf(vm, t);
    try keep(th, .{ .table = ks });
    defer th.top -= 1;
    for (0..ks.arr.items.len) |i| {
        const k = ks.arr.items[i];
        const v = t.get(k);
        const r = try th.call(f, &.{v});
        switch (what) {
            .map => out.set(vm.gpa, k, r),
            .filter => if (r.truthy()) out.set(vm.gpa, k, v),
        }
    }
    return .{ .table = out };
}

fn tMap(th: *Thread, args: []Value) Error!Value {
    return mapOrFilter(th, args, .map);
}

fn tFilter(th: *Thread, args: []Value) Error!Value {
    return mapOrFilter(th, args, .filter);
}

fn tFold(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try api.argTable(th, args, 0, "t");
    var acc = api.arg(args, 1);
    const f: Value = .{ .function = try api.argFunction(th, args, 2, "f") };
    const ks = keysOf(vm, t);
    try keep(th, .{ .table = ks });
    defer th.top -= 1;
    for (0..ks.arr.items.len) |i| {
        acc = try th.call(f, &.{ acc, t.get(ks.arr.items[i]) });
    }
    return acc;
}

fn tKeys(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    return .{ .table = keysOf(th.vm, t) };
}

const SortCtx = struct {
    th: *Thread,
    less: Value,
    failed: ?Error = null,

    fn lessThan(c: *SortCtx, a: Value, b: Value) bool {
        if (c.failed != null) return false;
        if (c.less != .null) {
            const r = c.th.call(c.less, &.{ a, b }) catch |e| {
                c.failed = e;
                return false;
            };
            return r.truthy();
        }
        if (a == .string and b == .string) return std.mem.lessThan(u8, a.string.bytes(), b.string.bytes());
        return c.th.lessThan(a, b) catch |e| {
            c.failed = e;
            return false;
        };
    }
};

/// sort(t, less?): stable, in place. The elements are sorted in a scratch
/// table on the stack (so they stay alive and in one place while less
/// runs) and written back.
fn tSort(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try api.argTable(th, args, 0, "t");
    const less = api.arg(args, 1);
    if (less != .null and less != .function) return api.argError(th, "less", 1, "function", less);
    const n = t.arr.items.len;
    if (n < 2) return .{ .table = t };
    const scratch = vm.newTable(n, 0);
    for (t.arr.items) |v| scratch.pushSlot(vm.gpa, v);
    try keep(th, .{ .table = scratch });
    defer th.top -= 1;
    var ctx: SortCtx = .{ .th = th, .less = less };
    std.sort.block(Value, scratch.arr.items, &ctx, SortCtx.lessThan);
    if (ctx.failed) |e| return e;
    if (t.arr.items.len != n) return vm.raise("table.sort: the list changed while it was sorted", .{});
    @memcpy(t.arr.items, scratch.arr.items);
    return .{ .table = t };
}

fn tInsert(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    const i = try api.argInt(th, args, 1, "i");
    const v = api.arg(args, 2);
    const n = t.arr.items.len;
    if (i < 0 or i > n) return th.vm.raise("table.insert: index {d} out of range (length {d})", .{ i, n });
    if (v == .null) return th.vm.raise("table.insert: null cannot be an element of a list", .{});
    t.insertAt(th.vm.gpa, @intCast(i), v);
    return .null;
}

fn tIndexOf(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    const value = api.arg(args, 1);
    var i: usize = 0;
    while (i < t.arr.items.len) : (i += 1) {
        if (try th.equal(t.arr.items[i], value)) return .{ .int = @intCast(i) };
    }
    return .{ .int = -1 };
}

fn tReverse(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    std.mem.reverse(Value, t.arr.items);
    return .{ .table = t };
}

/// a position of slice: negative counts from the end, clamped to 0..n
fn position(th: *Thread, args: []Value, i: usize, name: []const u8, n: i64, def: i64) Error!i64 {
    const v = api.arg(args, i);
    var p = if (v == .null) def else try api.argInt(th, args, i, name);
    if (p < 0) p += n;
    return std.math.clamp(p, 0, n);
}

fn tSlice(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    const n: i64 = @intCast(t.arr.items.len);
    const start = try position(th, args, 1, "start", n, 0);
    const stop = try position(th, args, 2, "end", n, n);
    const out = th.vm.newTable(@intCast(@max(0, stop - start)), 0);
    if (stop > start) {
        for (t.arr.items[@intCast(start)..@intCast(stop)]) |v| out.append(th.vm.gpa, v);
    }
    return .{ .table = out };
}
