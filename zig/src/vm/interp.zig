//! The interpreter: the loop that runs the register instruction set
//! (ops.zig), the inline caches its quickened instructions use, and the
//! operations with metamethods (ThreadOps) the rest of the VM calls.
//!
//! A frame's registers are base .. base + max_stack, and th.top is their
//! end whenever something can collect, call out or raise (spill). A call
//! lowers it to the end of its arguments; what lies above is dead (see
//! ops.zig) and the collector clears it.

const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const Value = root.Value;
const Table = root.Table;
const String = root.String;
const Thread = root.Thread;
const thread_mod = @import("thread.zig");
const Error = root.Error;
const gc = @import("gc.zig");
const ctypes = @import("../stdlib/ctypes.zig");
const corelib = @import("../stdlib/core.zig");
const ops = @import("ops.zig");
const Ic = @import("table.zig").Ic;

/// The operation of an arithmetic, bitwise or comparison instruction, as
/// the helpers below take it (at comptime from the loop, so that each
/// folds to its case).
pub const Op = enum {
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    band,
    bor,
    bxor,
    shl,
    shr,
    bnot,
    eq,
    lt,
    leq,

    pub fn symbol(op: Op) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .pow => "^",
            .band => "&",
            .bor => "|",
            .bxor, .bnot => "~",
            .shl => "<<",
            .shr => ">>",
            .eq => "==",
            .lt => "<",
            .leq => "<=",
        };
    }
};

// ---- inline caches (quickening)
//
// The first time a get_field, get_up_field, self, set_field or
// set_up_field with a constant string key runs, it is rewritten in place
// into its quickened form (ops.zig: get_field_q, ...), whose key operand
// is an index into the prototype's inline caches (Proto.ics) instead. A
// cache remembers the slot where the key was last found in the object
// itself: objects that got their keys in the same order (made by the same
// constructor) hit with one compare, no hashing and no shapes. Loads also
// remember what the metatables gave for the key, which holds while
//
//   - the object's metatable is the one the cache was filled with,
//   - the VM's shape_epoch has not moved: no table the cache walked
//     through (metatables, __index and __get tables, marked is_proto)
//     gained or lost a key, had a metamethod field stored, got another
//     metatable or was freed (so a stale pointer never matches), and
//   - the object never had the key (Table.keybits).
//
// Values are read from the remembered slot each time, so storing a new
// method into a class does not invalidate anything. A miss runs the
// original instruction (Ic.orig), which does the full lookup.

/// obj[key] through an inline cache. Null: a property (its getter in
/// `getter`) or the generic path.
pub inline fn icGet(vm: *root.VM, ic: *Ic, obj: Value, getter: *Value) ?Value {
    switch (obj) {
        .table => |t| {
            const ents = t.ents.items;
            const s = ic.own_slot;
            if (s < ents.len) {
                const k = ents[s].key;
                if (k == .string and k.string == ic.key) return ents[s].val;
            }
            if (ic.epoch == vm.shape_epoch and t.keybits & ic.keybit == 0 and icMetaHolds(vm, ic, t.meta)) {
                switch (ic.state) {
                    .holder => return ic.holder.?.ents.items[ic.slot].val,
                    .absent => return .null,
                    .getter => {
                        getter.* = ic.holder.?.ents.items[ic.slot].val;
                        return null;
                    },
                    .generic => return null,
                    .none => {},
                }
            }
        },
        .userdata => |u| {
            // (a userdata's metatable by identity only: a cache filled
            // structurally has not marked the metatable it saw)
            if (!ic.structural and u.meta == ic.meta and ic.epoch == vm.shape_epoch) {
                switch (ic.state) {
                    .holder => {
                        // (a method stored as null: the generic path)
                        const v = ic.holder.?.ents.items[ic.slot].val;
                        return if (v != .null) v else null;
                    },
                    .getter => {
                        getter.* = ic.holder.?.ents.items[ic.slot].val;
                        return null;
                    },
                    .generic => return null,
                    .none, .absent => {},
                }
            }
        },
        else => return null,
    }
    return icFill(vm, ic, obj, getter);
}

/// Whether an object's metatable is one the cache's lookup through the
/// metatables holds for: the same table, or (structural) one the lookup
/// reads the same from: no __get, __index the same table.
inline fn icMetaHolds(vm: *root.VM, ic: *Ic, meta: ?*Table) bool {
    if (!ic.structural) return meta == ic.meta;
    const m = meta orelse return false;
    if (m.keybits & ic.meta_bits != 0) return false;
    const it = ic.index_table orelse return true;
    const ents = m.ents.items;
    if (ic.index_slot >= ents.len) return false;
    const e = ents[ic.index_slot];
    return e.key == .string and e.key.string == vm.index_name and e.val == .table and e.val.table == it;
}

/// What the metatables give for the key, remembered in the cache.
fn icRemember(ic: *Ic, state: Ic.State, meta: ?*Table, holder: ?*Table, slot: u32, epoch: u64) void {
    ic.state = state;
    ic.meta = meta;
    ic.holder = holder;
    ic.slot = slot;
    ic.epoch = epoch;
}

/// A __get table's getter for the key, if any (the table is marked: a
/// getter added later must be seen).
fn icGetter(m: *Table, vm: *root.VM, key: Value) ?struct { *Table, u32 } {
    const g = m.getStr(vm.get_name);
    if (g != .table) return null;
    g.table.is_proto = true;
    const i = g.table.findSlot(key) orelse return null;
    if (g.table.ents.items[i].val == .null) return null;
    return .{ g.table, i };
}

/// Makes the cache check the object's first metatable structurally when
/// that is exact: it never had __get (its key bit is clear), and its
/// __index is a table at a slot (or it never had __index).
fn icStructural(vm: *root.VM, ic: *Ic, m: *Table) void {
    const get_bit = Table.keyBit(vm.get_name);
    if (m.keybits & get_bit != 0) return;
    if (m.findSlot(.{ .string = vm.index_name })) |i| {
        const v = m.ents.items[i].val;
        if (v != .table) return;
        ic.* = .{ .key = ic.key, .orig = ic.orig, .keybit = ic.keybit, .own_slot = ic.own_slot, .structural = true, .index_slot = i, .meta_bits = get_bit, .index_table = v.table };
    } else {
        const index_bit = Table.keyBit(vm.index_name);
        if (m.keybits & index_bit != 0) return;
        ic.* = .{ .key = ic.key, .orig = ic.orig, .keybit = ic.keybit, .own_slot = ic.own_slot, .structural = true, .meta_bits = get_bit | index_bit };
    }
}

/// The slow path of icGet: the lookup the way getFastG and getChain do it,
/// remembering where it went. Every table it passes is marked is_proto.
noinline fn icFill(vm: *root.VM, ic: *Ic, obj: Value, getter: *Value) ?Value {
    const key: Value = .{ .string = ic.key };
    const epoch = vm.shape_epoch;
    switch (obj) {
        .table => |t0| {
            if (t0.findSlot(key)) |i| {
                ic.own_slot = i;
                return t0.ents.items[i].val;
            }
            // the first metatable: by identity while the site has seen one;
            // once it sees another (a metatable made per object), by what
            // the lookup reads from it when the key bits and one slot can
            // tell (see icMetaHolds), so those are neither marked nor misses
            const polymorphic = ic.structural or (ic.state != .none and ic.meta != t0.meta);
            ic.structural = false;
            if (t0.meta) |m0| {
                if (polymorphic) icStructural(vm, ic, m0);
            }
            var t = t0;
            var depth: usize = 0;
            while (depth < 100) : (depth += 1) {
                const m = t.meta orelse {
                    icRemember(ic, .absent, t0.meta, null, 0, epoch);
                    return .null;
                };
                if (depth > 0 or !ic.structural) m.is_proto = true;
                if (icGetter(m, vm, key)) |g| {
                    icRemember(ic, .getter, t0.meta, g[0], g[1], epoch);
                    getter.* = g[0].ents.items[g[1]].val;
                    return null;
                }
                switch (m.getStr(vm.index_name)) {
                    .table => |n| t = n,
                    .null => {
                        icRemember(ic, .absent, t0.meta, null, 0, epoch);
                        return .null;
                    },
                    else => break,
                }
                t.is_proto = true;
                if (t.findSlot(key)) |i| {
                    icRemember(ic, .holder, t0.meta, t, i, epoch);
                    return t.ents.items[i].val;
                }
            }
            icRemember(ic, .generic, t0.meta, null, 0, epoch);
            return null;
        },
        .userdata => |u| {
            const m = u.meta orelse return null;
            m.is_proto = true;
            ic.structural = false;
            if (icGetter(m, vm, key)) |g| {
                icRemember(ic, .getter, m, g[0], g[1], epoch);
                getter.* = g[0].ents.items[g[1]].val;
                return null;
            }
            icRemember(ic, .generic, m, null, 0, epoch);
            const idx = m.getStr(vm.index_name);
            if (idx != .table) return null;
            const n = idx.table;
            n.is_proto = true;
            const i = n.findSlot(key) orelse return null;
            const v = n.ents.items[i].val;
            if (v == .null) return null;
            icRemember(ic, .holder, m, n, i, epoch);
            return v;
        },
        else => return null,
    }
}

/// obj[key] = val through an inline cache: only an existing key of the
/// object itself (what setFast stores inline whatever the metatable has).
pub inline fn icStore(vm: *root.VM, ic: *Ic, obj: Value, val: Value) bool {
    if (obj != .table) return false;
    const t = obj.table;
    const ents = t.ents.items;
    const s = ic.own_slot;
    if (s < ents.len) {
        const k = ents[s].key;
        if (k == .string and k.string == ic.key) {
            t.storeAt(vm.gpa, s, val);
            return true;
        }
    }
    const i = t.findSlot(.{ .string = ic.key }) orelse return false;
    ic.own_slot = i;
    t.storeAt(vm.gpa, i, val);
    return true;
}

/// Which built-in iterator f is (0 keys, 1 values, 2 entries) when it is
/// one forin_prep walks in the loop (of a table; anything else, null
/// included, goes to the call as before).
pub inline fn iterKind(f: *root.Closure) ?i64 {
    const n = f.native orelse return null;
    if (n == &corelib.coreValues) return 1;
    if (n == &corelib.coreEntries) return 2;
    if (n == &corelib.coreKeys) return 0;
    return null;
}

/// == without a call: null, booleans and strings (whose __eq is
/// never asked). Null: numbers of mixed kinds, tables, the rest.
pub inline fn eqInline(a: Value, b: Value) ?bool {
    if (a == .null or b == .null) return a == .null and b == .null;
    if (a == .string and b == .string) return a.string.eql(b.string);
    if (a == .bool and b == .bool) return a.bool == b.bool;
    return null;
}

/// Executes frames until the frame depth drops back to stop_depth.
pub fn run(th: *Thread, stop_depth: usize) Error!void {
    th.run_depth += 1;
    defer th.run_depth -= 1;
    // the trace check costs about 3% on call-heavy code when it sits in
    // every opcode, so the loop exists twice: with and without it (the
    // profiler and the debugger use the same hook)
    const vm = th.vm;
    if (vm.tracer != null or vm.opstats != null or vm.profiler != null or vm.debugger != null) return runLoop(th, stop_depth, true);
    return runLoop(th, stop_depth, false);
}

fn runLoop(th: *Thread, stop_depth: usize, comptime trace: bool) Error!void {
    const vm = th.vm;
    outer: while (true) {
        const n = th.frames.items.len;
        if (n <= stop_depth) return;
        var fi = n - 1;
        const frame = th.frames.items[fi];
        var cl = frame.cl;
        var proto = cl.proto orelse return vm.raise("internal error: native frame in interpreter loop", .{});
        var code = proto.code;
        var consts = proto.consts;
        var base: usize = frame.base;
        // the end of the frame's registers
        var ftop: usize = base + proto.max_stack;
        var pc: usize = frame.pc;
        var stack: [*]Value = th.stack.ptr;
        var ins: u32 = undefined;
        th.top = ftop;
        sw: switch (fetch(trace, th, code, fi, base, &pc, ftop, &ins)) {
            // ---- loads
            .move => {
                stack[base + ops.argA(ins)] = stack[base + ops.argB(ins)];
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .load_k => {
                stack[base + ops.argA(ins)] = consts[ops.argBx(ins)];
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .load_int => {
                putRaw(&stack[base + ops.argA(ins)], .int, @bitCast(@as(i64, ops.argSBx(ins))));
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .load_bool => {
                putRaw(&stack[base + ops.argA(ins)], .bool, @intFromBool(ops.argB(ins) != 0));
                if (ops.argC(ins) != 0) pc += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .load_null => {
                const a = base + ops.argA(ins);
                @memset(stack[a .. a + ops.argB(ins) + 1], .null);
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .closure => {
                spill(th, fi, pc, ftop);
                gc.safePoint(vm, th) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                const c = th.makeClosure(th.frames.items[fi], proto.children[ops.argBx(ins)]);
                stack[base + ops.argA(ins)] = .{ .function = c };
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- upvalues
            .get_upval => {
                stack[base + ops.argA(ins)] = cl.upvals[ops.argB(ins)].get();
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .set_upval => {
                const v = stack[base + ops.argA(ins)];
                const u = cl.upvals[ops.argB(ins)];
                u.set(v);
                // a closed upvalue is an object of its own (open, the value
                // is on a stack: rescanned)
                if (u.th == null) gc.barrier(vm, &u.obj, v);
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .close => {
                th.closeUpvalues(base + ops.argA(ins));
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- arithmetic
            inline .add, .sub, .mul, .div, .mod, .pow, .band, .bor, .bxor, .shl, .shr => |op| {
                const core = comptime coreOf(op);
                const b = stack[base + ops.argB(ins)];
                const c = rk(stack, base, consts, ins);
                switch (core) {
                    .add, .sub, .mul, .div, .mod => if (numArith(core, b, c)) |r| {
                        putValue(&stack[base + ops.argA(ins)], r);
                        continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                    },
                    .band, .bor, .bxor, .shl, .shr => if (b == .int and c == .int) {
                        if (bitop(core, b.int, c.int)) |r| {
                            putValue(&stack[base + ops.argA(ins)], r);
                            continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                        }
                    },
                    else => {},
                }
                spill(th, fi, pc, ftop);
                const r = th.arithMeta(core, b, c) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                stack[base + ops.argA(ins)] = r;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .neg => {
                const a = stack[base + ops.argB(ins)];
                switch (a) {
                    .int => |i| stack[base + ops.argA(ins)] = .{ .int = 0 -% i },
                    .float => |f| stack[base + ops.argA(ins)] = .{ .float = -f },
                    else => {
                        spill(th, fi, pc, ftop);
                        const f = metamethod(a, .null, "__unm");
                        if (f != .function) {
                            vm.setError("attempt to negate a {s} value", .{a.typeName()});
                            try th.handleError(error.Slang, stop_depth);
                            continue :outer;
                        }
                        const r = th.call(f, &.{a}) catch |e| {
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        stack = th.stack.ptr;
                        stack[base + ops.argA(ins)] = r;
                    },
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .not => {
                // (read first: a tagged union written in place takes its tag
                // before the operand is read)
                const v = stack[base + ops.argB(ins)];
                stack[base + ops.argA(ins)] = .{ .bool = !v.truthy() };
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .bnot => {
                const a = stack[base + ops.argB(ins)];
                if (a == .int) {
                    stack[base + ops.argA(ins)] = .{ .int = ~a.int };
                } else {
                    spill(th, fi, pc, ftop);
                    const r = bnotSlow(th, a) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    stack = th.stack.ptr;
                    stack[base + ops.argA(ins)] = r;
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- compare and branch
            inline .eq, .lt, .le, .gt, .ge => |op| {
                const core: Op = comptime switch (op) {
                    .eq => .eq,
                    .lt, .gt => .lt,
                    else => .leq,
                };
                const swap = comptime (op == .gt or op == .ge);
                const x = stack[base + ops.argB(ins)];
                const y = rk(stack, base, consts, ins);
                const l = if (swap) y else x;
                const r = if (swap) x else y;
                var res: bool = undefined;
                if (l == .int and r == .int) {
                    res = switch (core) {
                        .lt => l.int < r.int,
                        .leq => l.int <= r.int,
                        else => l.int == r.int,
                    };
                } else if (l == .float and r == .float) {
                    res = switch (core) {
                        .lt => l.float < r.float,
                        .leq => l.float <= r.float,
                        else => l.float == r.float,
                    };
                } else if (if (core == .eq) eqInline(l, r) else null) |e| {
                    res = e;
                } else {
                    spill(th, fi, pc, ftop);
                    res = compareSlow(th, core, l, r) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    stack = th.stack.ptr;
                }
                if (res != (ops.argA(ins) != 0)) pc += 1 else takeJump(code, &pc);
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .@"test" => {
                const v = stack[base + ops.argA(ins)];
                if (v.truthy() != ops.argK(ins)) pc += 1 else takeJump(code, &pc);
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .test_set => {
                const v = stack[base + ops.argB(ins)];
                if (v.truthy() != ops.argK(ins)) {
                    pc += 1;
                } else {
                    stack[base + ops.argA(ins)] = v;
                    takeJump(code, &pc);
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .jump => {
                const off = ops.argSBx(ins);
                if (off < 0) {
                    spill(th, fi, pc, ftop);
                    gc.safePoint(vm, th) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                }
                pc = @intCast(@as(i64, @intCast(pc)) + off);
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- tables
            .new_table => {
                spill(th, fi, pc, ftop);
                gc.safePoint(vm, th) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack[base + ops.argA(ins)] = .{ .table = vm.newTable(ops.argB(ins), ops.argC(ins)) };
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            inline .get_field, .get_index, .get_up_field => |op| {
                if (op != .get_index) quicken: {
                    const key = quickenable(proto, code, pc, consts[ops.argC(ins)], op) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, key, op);
                    continue :sw if (op == .get_field) .get_field_q else .get_up_field_q;
                }
                const obj = switch (op) {
                    .get_up_field => cl.upvals[ops.argB(ins)].get(),
                    else => stack[base + ops.argB(ins)],
                };
                const key = if (op == .get_index) stack[base + ops.argC(ins)] else consts[ops.argC(ins)];
                var getter: Value = .null;
                if (getFastG(vm, obj, key, &getter)) |v| {
                    stack[base + ops.argA(ins)] = v;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                if (getter != .null) {
                    const switched = callAccessor(th, fi, pc, base, ftop, getter, obj, null, @intCast(ops.argA(ins))) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    if (switched) continue :outer;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                spill(th, fi, pc, ftop);
                const v = th.getTable(obj, key) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                stack[base + ops.argA(ins)] = v;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            inline .get_field_q, .get_up_field_q => |op| {
                const ic = &proto.ics.items[ops.cacheOf(ins)];
                const obj = if (op == .get_up_field_q) cl.upvals[ops.argB(ins)].get() else stack[base + ops.argB(ins)];
                var getter: Value = .null;
                if (icGet(vm, ic, obj, &getter)) |v| {
                    stack[base + ops.argA(ins)] = v;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                if (getter != .null) {
                    const switched = callAccessor(th, fi, pc, base, ftop, getter, obj, null, @intCast(ops.argA(ins))) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    if (switched) continue :outer;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                // a miss: the instruction as it was compiled
                ins = ic.orig;
                continue :sw if (op == .get_field_q) .get_field else .get_up_field;
            },
            inline .set_field, .set_index, .set_up_field => |op| {
                if (op != .set_index) quicken: {
                    const key = quickenable(proto, code, pc, consts[ops.argB(ins)], op) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, key, op);
                    continue :sw if (op == .set_field) .set_field_q else .set_up_field_q;
                }
                const obj = if (op == .set_up_field) cl.upvals[ops.argA(ins)].get() else stack[base + ops.argA(ins)];
                const key = if (op == .set_index) stack[base + ops.argB(ins)] else consts[ops.argB(ins)];
                const val = rk(stack, base, consts, ins);
                if (setFast(vm, obj, key, val)) continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                if (findSetter(vm, obj, key)) |f| {
                    const switched = callAccessor(th, fi, pc, base, ftop, f, obj, val, thread_mod.dest_drop) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    if (switched) continue :outer;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                spill(th, fi, pc, ftop);
                th.setTable(obj, key, val) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            inline .set_field_q, .set_up_field_q => |op| {
                const ic = &proto.ics.items[ops.cacheOf(ins)];
                const obj = if (op == .set_up_field_q) cl.upvals[ops.argA(ins)].get() else stack[base + ops.argA(ins)];
                if (icStore(vm, ic, obj, rk(stack, base, consts, ins))) {
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                ins = ic.orig;
                continue :sw if (op == .set_field_q) .set_field else .set_up_field;
            },
            .init_field => {
                const t = stack[base + ops.argA(ins)].table;
                t.set(vm.gpa, consts[ops.argB(ins)], rk(stack, base, consts, ins));
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .self => {
                quicken: {
                    if (!ops.argK(ins)) break :quicken;
                    const key = quickenable(proto, code, pc, consts[ops.argC(ins)], .self) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, key, .self);
                    continue :sw .self_q;
                }
                const obj = stack[base + ops.argB(ins)];
                const key = rk(stack, base, consts, ins);
                const a = base + ops.argA(ins);
                var f: Value = undefined;
                if (getFast(vm, obj, key)) |v| {
                    f = v;
                } else {
                    spill(th, fi, pc, ftop);
                    f = th.getTable(obj, key) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    stack = th.stack.ptr;
                }
                stack[a + 1] = obj;
                stack[a] = f;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .self_q => {
                const ic = &proto.ics.items[ops.cacheOf(ins)];
                const obj = stack[base + ops.argB(ins)];
                var getter: Value = .null;
                if (icGet(vm, ic, obj, &getter)) |f| {
                    const a = base + ops.argA(ins);
                    stack[a + 1] = obj;
                    stack[a] = f;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                ins = ic.orig;
                continue :sw .self;
            },
            .set_list => {
                const a = base + ops.argA(ins);
                const t = stack[a].table;
                var start: usize = ops.argC(ins);
                if (ops.argK(ins)) {
                    start = code[pc];
                    pc += 1;
                }
                for (0..ops.argB(ins)) |i| t.set(vm.gpa, .{ .int = @intCast(start + i) }, stack[a + 1 + i]);
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- metatables, types
            .get_meta => {
                const v = stack[base + ops.argB(ins)];
                stack[base + ops.argA(ins)] = switch (v) {
                    .table => |t| Value.fromTable(t.meta),
                    .userdata => |u| Value.fromTable(u.meta),
                    else => .null,
                };
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .set_meta => {
                th.setMeta(stack[base + ops.argA(ins)], stack[base + ops.argB(ins)]) catch |e| {
                    spill(th, fi, pc, ftop);
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .type => {
                spill(th, fi, pc, ftop);
                const r = th.typeOf(stack[base + ops.argB(ins)]) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                stack[base + ops.argA(ins)] = r;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- functions
            .call => {
                spill(th, fi, pc, ftop);
                gc.safePoint(vm, th) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                const fn_idx = base + ops.argA(ins);
                const nargs: usize = ops.argB(ins);
                th.top = fn_idx + 1 + nargs;
                const is_slang = th.precall(fn_idx, nargs) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                if (is_slang) {
                    // the callee's frame, without leaving the switch
                    fi = th.frames.items.len - 1;
                    const fr = th.frames.items[fi];
                    cl = fr.cl;
                    proto = cl.proto.?;
                    code = proto.code;
                    consts = proto.consts;
                    base = fr.base;
                    ftop = base + proto.max_stack;
                    pc = fr.pc;
                    th.top = ftop;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                // a native ran: its result is in R[A]
                th.top = ftop;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .call_spread => {
                spill(th, fi, pc, ftop);
                gc.safePoint(vm, th) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                const fn_idx = base + ops.argA(ins);
                const fixed: usize = ops.argB(ins);
                const at = fn_idx + 1 + fixed;
                const list = stack[at];
                if (list != .table) {
                    vm.setError("attempt to spread a {s} value", .{list.typeName()});
                    try th.handleError(error.Slang, stop_depth);
                    continue :outer;
                }
                // every index up to the largest: a gap is passed as null
                const lt = list.table;
                const spread_n = lt.spreadLen();
                th.ensure(at + spread_n + 8) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                for (0..spread_n) |i| stack[at + i] = lt.getInt(@intCast(i));
                th.top = at + spread_n;
                const is_slang = th.precall(fn_idx, fixed + spread_n) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                if (is_slang) continue :outer;
                th.top = ftop;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .@"return", .return_null => {
                const res: Value = if (ops.opOf(ins) == .@"return") stack[base + ops.argA(ins)] else .null;
                const fn_idx = base - 1;
                const dest = th.frames.items[fi].dest;
                th.popFrame();
                th.top = fn_idx;
                if (dest == thread_mod.dest_push) {
                    th.stack[fn_idx] = res;
                    th.top = fn_idx + 1;
                } else if (dest != thread_mod.dest_drop) {
                    // an accessor's result, into its caller's register
                    th.stack[th.frames.items[th.frames.items.len - 1].base + dest] = res;
                }
                if (th.frames.items.len == stop_depth) return;
                // the caller's frame, without leaving the switch
                fi = th.frames.items.len - 1;
                const fr = th.frames.items[fi];
                cl = fr.cl;
                proto = cl.proto orelse continue :outer;
                code = proto.code;
                consts = proto.consts;
                base = fr.base;
                ftop = base + proto.max_stack;
                pc = fr.pc;
                th.top = ftop;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            // ---- errors
            .try_begin => {
                const a = base + ops.argA(ins);
                th.pushHandler(.{
                    .frame = @intCast(fi),
                    .pc = @intCast(@as(i64, @intCast(pc)) + ops.argSBx(ins)),
                    // (handleError puts the error at top: R[A])
                    .top = @intCast(a),
                    .close_from = @intCast(a),
                });
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .try_end => {
                _ = th.handlers.pop();
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .throw => {
                const v = stack[base + ops.argA(ins)];
                spill(th, fi, pc, ftop);
                vm.setErrorFromValue(v);
                try th.handleError(error.Slang, stop_depth);
                continue :outer;
            },
            // ---- loops
            .for_loop => {
                // the update and the condition of a for; the jump word after
                // it goes to the body and carries the flags
                const ra = base + ops.argA(ins);
                const j = code[pc];
                const flags = ops.argA(j);
                const step = if (flags & ops.for_flags.step_k != 0) consts[ops.argB(ins)] else stack[base + ops.argB(ins)];
                const limit = if (flags & ops.for_flags.limit_k != 0) consts[ops.argC(ins)] else stack[base + ops.argC(ins)];
                const is_sub = flags & ops.for_flags.sub != 0;
                const i = stack[ra];
                // the jump's offset from the word after it: the body, or
                // the condition (two before the body) to compare in full
                var off: i64 = ops.argSBx(j);
                var cont = true;
                if (i == .int and step == .int and limit == .int) {
                    const k = if (is_sub) i.int -% step.int else i.int +% step.int;
                    putRaw(&stack[ra], .int, @bitCast(k));
                    const c = if (flags & ops.for_flags.leq != 0) k <= limit.int else k < limit.int;
                    cont = c != (flags & ops.for_flags.negate != 0);
                } else {
                    const r = (if (is_sub) numArith(.sub, i, step) else numArith(.add, i, step)) orelse slow: {
                        spill(th, fi, pc, ftop);
                        const r = th.arithMeta(if (is_sub) .sub else .add, i, step) catch |e| {
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        stack = th.stack.ptr;
                        break :slow r;
                    };
                    putValue(&stack[ra], r);
                    if (r.isNumber() and limit.isNumber()) {
                        const x = r.asNumber();
                        const y = limit.asNumber();
                        const c = if (flags & ops.for_flags.leq != 0) x <= y else x < y;
                        cont = c != (flags & ops.for_flags.negate != 0);
                    } else {
                        off -= 2;
                    }
                }
                if (cont) {
                    spill(th, fi, pc, ftop);
                    gc.safePoint(vm, th) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    pc = @intCast(@as(i64, @intCast(pc)) + 1 + off);
                } else {
                    pc += 1;
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .forin_prep => {
                // R[A] = f, R[A+1] = x: the built-in keys, values or entries
                // of a table become a walk of the table in the loop
                // (forin_next) with nothing allocated; anything else is the
                // call f(x)
                const a = base + ops.argA(ins);
                const f = stack[a];
                const x = stack[a + 1];
                if (f == .function and x == .table) {
                    if (iterKind(f.function)) |kind| {
                        stack[a] = x;
                        stack[a + 1] = .{ .int = kind };
                        continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                    }
                }
                ins = ops.abc(.call, ops.argA(ins), 1, 0, false);
                continue :sw .call;
            },
            .forin_next => {
                const a = base + ops.argA(ins);
                const it = stack[a];
                if (it == .table) {
                    var state: u64 = @intCast(stack[a + 1].int);
                    if (it.table.nextLive(&state)) |entry| {
                        stack[a + 1] = .{ .int = @intCast(state) };
                        stack[a + 2] = switch (state & 3) {
                            0 => entry.key,
                            1 => entry.val,
                            else => .{ .table = corelib.entryPair(vm, entry) },
                        };
                        // the second word: to the pattern
                        pc += 2 + @as(usize, @intCast(ops.argSBx(code[pc + 1])));
                    } else {
                        // the first: the end
                        pc += 1 + @as(usize, @intCast(ops.argSBx(code[pc])));
                    }
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                // an iterator function: the call after the two words
                pc += 2;
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            _ => {
                spill(th, fi, pc, ftop);
                return vm.raise("unknown opcode {d}", .{ins & 0x7F});
            },
        }
    }
}

/// Fetches the next instruction and returns its opcode. The trace build
/// (profiler, debugger, SLANG_TRACE, SLANG_OPSTATS) also runs the hook and
/// keeps the frame's pc current at every instruction.
inline fn fetch(comptime trace: bool, th: *Thread, code: []const u32, fi: usize, base: usize, pc: *usize, ftop: usize, ins: *u32) ops.Op {
    ins.* = code[pc.*];
    if (trace) {
        th.top = ftop;
        traceInstruction(th, fi, base, pc.*, ins.*);
    }
    pc.* += 1;
    if (trace) th.frames.items[fi].pc = @intCast(pc.*);
    return ops.opOf(ins.*);
}

/// Before anything that can raise, call, yield or collect: the frame's pc
/// (error locations, tracebacks) and th.top at the end of its registers.
inline fn spill(th: *Thread, fi: usize, pc: usize, ftop: usize) void {
    th.top = ftop;
    th.frames.items[fi].pc = @intCast(pc);
}

/// Writes a value of a kind without a heap pointer as one 16-byte store
/// (payload, tag). A value written in parts (an 8-byte payload, a 1-byte
/// tag), as Zig writes a tagged union, and then copied as a whole by the
/// next instruction (a 16-byte load) stalls that load until the parts
/// reach the cache: the store cannot be forwarded. Arithmetic chains
/// (x = x * a + b) paid that on every operation.
inline fn putRaw(dst: *Value, tag: root.Kind, bits: u64) void {
    const words: *[2]u64 = @ptrCast(dst);
    words.* = .{ bits, @backingInt(tag) };
}

/// A value (an arithmetic result) into a register in one store when it is
/// a number.
inline fn putValue(dst: *Value, v: Value) void {
    switch (v) {
        .int => |i| putRaw(dst, .int, @bitCast(i)),
        .float => |f| putRaw(dst, .float, @bitCast(f)),
        else => dst.* = v,
    }
}

/// RK(C): constant C when k is set, else register C.
inline fn rk(stack: [*]Value, base: usize, consts: []const Value, ins: u32) Value {
    return if (ops.argK(ins)) consts[ops.argC(ins)] else stack[base + ops.argC(ins)];
}

/// Takes the jump that follows a compare or a test, when it goes forward;
/// a backward one runs as itself (a safe point).
inline fn takeJump(code: []const u32, pc: *usize) void {
    const off = ops.argSBx(code[pc.*]);
    if (off >= 0) pc.* += 1 + @as(usize, @intCast(off));
}

/// The operation an arithmetic opcode performs.
fn coreOf(comptime op: ops.Op) Op {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .band => .band,
        .bor => .bor,
        .bxor => .bxor,
        .shl => .shl,
        .shr => .shr,
        else => unreachable,
    };
}

/// A property's getter (val null) or setter, called above the frame's
/// registers: its result goes to the register dest (or is dropped). True
/// when it is a slang function whose frame runs next.
fn callAccessor(th: *Thread, fi: usize, pc: usize, base: usize, ftop: usize, f: Value, obj: Value, val: ?Value, dest: u16) Error!bool {
    spill(th, fi, pc, ftop);
    const nargs: usize = if (val != null) 2 else 1;
    try th.ensure(ftop + 1 + nargs);
    th.stack[ftop] = f;
    th.stack[ftop + 1] = obj;
    if (val) |v| th.stack[ftop + 2] = v;
    th.top = ftop + 1 + nargs;
    if (try th.precall(ftop, nargs)) {
        th.frames.items[th.frames.items.len - 1].dest = dest;
        return true;
    }
    // a native accessor ran already: its result where it was called
    if (dest != thread_mod.dest_drop) th.stack[base + dest] = th.stack[ftop];
    th.top = ftop;
    return false;
}

// ---- quickening (see zig's inline caches)

/// The key of a get_field, get_up_field, self or set_field that can be
/// quickened: a constant string (for a store not a metamethod name), the
/// instruction not quickened already (after a miss it runs as itself),
/// room for another cache that the instruction can address.
inline fn quickenable(proto: *root.Proto, code: []u32, pc: usize, k: Value, comptime op: ops.Op) ?*String {
    if (k != .string) return null;
    if (ops.opOf(code[pc - 1]) != op) return null;
    const store = op == .set_field or op == .set_up_field;
    const room: usize = if (store) ops.max_store_caches else ops.max_load_caches;
    if (proto.ics.items.len >= room) return null;
    if (store) {
        const b = k.string.bytes();
        if (b.len >= 2 and b[0] == '_' and b[1] == '_') return null;
    }
    return k.string;
}

/// Gives the instruction a cache and rewrites it at pc - 1 into its
/// quickened form, which it returns.
fn quicken(vm: *root.VM, proto: *root.Proto, code: []u32, pc: usize, ins: u32, key: *String, comptime op: ops.Op) u32 {
    const idx: u32 = @intCast(proto.ics.items.len);
    proto.ics.append(vm.gpa, .{ .key = key, .orig = ins, .keybit = Table.keyBit(key) }) catch root.oom();
    const quick: u32 = switch (op) {
        .get_field => ops.abc(.get_field_q, ops.argA(ins), ops.argB(ins), idx & 0xFF, idx >= 256),
        .get_up_field => ops.abc(.get_up_field_q, ops.argA(ins), ops.argB(ins), idx & 0xFF, idx >= 256),
        .self => ops.abc(.self_q, ops.argA(ins), ops.argB(ins), idx & 0xFF, idx >= 256),
        .set_field => ops.abc(.set_field_q, ops.argA(ins), idx, ops.argC(ins), ops.argK(ins)),
        .set_up_field => ops.abc(.set_up_field_q, ops.argA(ins), idx, ops.argC(ins), ops.argK(ins)),
        else => unreachable,
    };
    code[pc - 1] = quick;
    return quick;
}

pub fn traceInstruction(th: *Thread, fi: usize, base: usize, pc: usize, ins: u32) void {
    if (th.vm.profiler) |p| p.check(th);
    if (th.vm.debugger) |dbg| dbg.check(th, fi, pc);
    if (th.vm.opstats) |s| s.record(th, fi, pc, ins);
    if (th.vm.tracer) |t| t.instruction(th, fi, base, pc, ins);
}

/// get_index's inline cases: a table (then __index tables), a buffer
/// element, a userdata's method. Null when the generic path (getTable)
/// must run.
pub inline fn getFast(vm: *root.VM, obj: Value, key: Value) ?Value {
    var getter: Value = .null;
    return getFastG(vm, obj, key, &getter);
}

/// getFast that also tells, on a miss, the getter of the property it met
/// (null when the miss is for another reason): found once, called by the
/// instruction.
pub inline fn getFastG(vm: *root.VM, obj: Value, key: Value, getter: *Value) ?Value {
    if (obj == .table) {
        const t = obj.table;
        const v = switch (key) {
            .string => |s| t.getStr(s),
            .int => |i| t.getInt(i),
            else => t.get(key),
        };
        if (v != .null or t.meta == null) return v;
        // a key holding null is present: __index is for absent keys
        if (t.has(key)) return .null;
        // a miss on a table with a metatable: walk __index tables inline,
        // leaving functions and properties (__get) to the slow path
        return getChain(vm, t, key, getter);
    } else if (obj == .userdata and key == .int) {
        // an element of a buffer of scalars
        return ctypes.bufferGet(obj.userdata, key.int);
    } else if (obj == .userdata and key == .string) {
        // a method of a userdata: its metatable's __index table (a
        // property goes to the slow path)
        if (obj.userdata.meta) |m| {
            const g = getterOf(vm, m, key);
            if (g != .null) {
                getter.* = g;
                return null;
            }
            const idx = m.getStr(vm.index_name);
            if (idx == .table) {
                const v = idx.table.getStr(key.string);
                if (v != .null) return v;
            }
        }
    }
    return null;
}

/// set_index's inline cases; false when the generic path (setTable) must
/// run.
pub inline fn setFast(vm: *root.VM, obj: Value, key: Value, val: Value) bool {
    if (obj == .table and key == .string) {
        // inline unless the store could go to a metamethod: the key is new
        // and the metatable could have a setter or __newindex for it (see
        // newKeyInline)
        const t = obj.table;
        const s = key.string;
        if (t.meta) |m| {
            if (t.replaceStr(vm.gpa, s, val)) return true;
            if (!newKeyInline(vm, m)) return false;
        }
        t.setStr(vm.gpa, s, val);
        return true;
    } else if (obj == .userdata and key == .int) {
        // an element of a buffer of scalars
        return ctypes.bufferSet(obj.userdata, key.int, val);
    }
    return false;
}

/// A comparison that is not int with int or float with float: mixed
/// numbers, metamethods, the error; as the core eq, lt and leq do it.
pub fn compareSlow(th: *Thread, comptime op: Op, a: Value, b: Value) Error!bool {
    if (op == .eq) {
        if (a.kind() == b.kind() and (a == .table or a == .userdata)) {
            const f = metamethod(a, b, "__eq");
            if (f == .function) return (try th.call(f, &.{ a, b })).truthy();
        }
        return a.equals(b);
    }
    const is_lt = op == .lt;
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
        return if (is_lt) x < y else x <= y;
    }
    const f = metamethod(a, b, if (is_lt) "__lt" else "__le");
    if (f == .function) return (try th.call(f, &.{ a, b })).truthy();
    return th.vm.raiseKind("type", "attempt to compare {s} {s} {s}", .{ a.typeName(), if (is_lt) "<" else "<=", b.typeName() });
}

/// What makes a store of a new key leave the inline path: the metatable
/// has __newindex, __get or __set.
const store_flags = Table.mf_newindex | Table.mf_get | Table.mf_set;

/// Whether a new key of a table with metatable m is stored inline: m has
/// no __newindex, __get or __set, and no __index table whose chain could
/// hold an inherited setter or getter (the generic path walks it).
inline fn newKeyInline(vm: *root.VM, m: *Table) bool {
    if (m.metaFlags(vm.newindex_name, vm.get_name, vm.set_name) & store_flags != 0) return false;
    return m.getStr(vm.index_name) != .table;
}

/// The setter of a property obj does not hold itself: from the __set of
/// its metatable or, inherited, of the metatables along its __index
/// tables; null when there is none, or a getter comes first (the generic
/// path raises read-only).
pub fn findSetter(vm: *root.VM, obj: Value, key: Value) ?Value {
    var m: *Table = switch (obj) {
        .table => |t| blk: {
            if (t.has(key)) return null;
            break :blk t.meta orelse return null;
        },
        .userdata => |u| u.meta orelse return null,
        else => return null,
    };
    var depth: usize = 0;
    while (depth < 100) : (depth += 1) {
        const flags = m.metaFlags(vm.newindex_name, vm.get_name, vm.set_name);
        if (flags & Table.mf_set != 0) {
            const st = m.getStr(vm.set_name);
            if (st == .table) {
                const f = st.table.get(key);
                if (f != .null) return f;
            }
        }
        if (flags & Table.mf_get != 0 and hasGetter(vm, m, key)) return null;
        const idx = m.getStr(vm.index_name);
        if (idx != .table) return null;
        m = idx.table.meta orelse return null;
    }
    return null;
}

/// The getter for key in metatable m's __get table, or null.
inline fn getterOf(vm: *root.VM, m: *Table, key: Value) Value {
    if (m.metaFlags(vm.newindex_name, vm.get_name, vm.set_name) & Table.mf_get == 0) return .null;
    const g = m.getStr(vm.get_name);
    if (g != .table) return .null;
    return g.table.get(key);
}

/// Whether metatable m has a getter for key in its __get table.
inline fn hasGetter(vm: *root.VM, m: *Table, key: Value) bool {
    if (m.metaFlags(vm.newindex_name, vm.get_name, vm.set_name) & Table.mf_get == 0) return false;
    const g = m.getStr(vm.get_name);
    return g == .table and g.table.get(key) != .null;
}

/// The __index chain over tables for a key t0 does not have: the value
/// (null when the chain ends without one), or null when an __index
/// function, a property or anything else needs the generic path
/// (getTable).
inline fn getChain(vm: *root.VM, t0: *Table, key: Value, getter: *Value) ?Value {
    var t = t0;
    var depth: usize = 0;
    while (depth < 100) : (depth += 1) {
        const m = t.meta orelse return .null;
        const g = getterOf(vm, m, key);
        if (g != .null) {
            getter.* = g;
            return null;
        }
        const idx = m.getStr(vm.index_name);
        switch (idx) {
            .table => |n| t = n,
            .null => return .null,
            else => return null,
        }
        const v = t.get(key);
        if (v != .null or t.has(key)) return v;
    }
    return null;
}

/// a value's type for an error: a userdata's own type name
fn typeNameOf(v: Value) []const u8 {
    if (v == .userdata) return v.userdata.tname;
    return v.typeName();
}

fn keyDesc(buf: []u8, key: Value) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (key == .string) {
        w.print("\"{s}\"", .{key.string.bytes()}) catch {};
    } else {
        root.format.writeValue(&w, key) catch {};
    }
    return w.buffered();
}

/// The metatable of a table or userdata value, or null.
pub fn metaOf(v: Value) ?*Table {
    return switch (v) {
        .table => |t| t.meta,
        .userdata => |u| u.meta,
        else => null,
    };
}

/// Looks up the function `name` in the metatable of a and then of b.
pub fn metamethod(a: Value, b: Value, name: []const u8) Value {
    if (metaOf(a)) |m| {
        const f = m.getName(name);
        if (f == .function) return f;
    }
    if (metaOf(b)) |m| {
        const f = m.getName(name);
        if (f == .function) return f;
    }
    return .null;
}

fn arithMetaName(op: Op) []const u8 {
    return switch (op) {
        .add => "__add",
        .sub => "__sub",
        .mul => "__mul",
        .div => "__div",
        .mod => "__mod",
        .pow => "__pow",
        .band => "__band",
        .bor => "__bor",
        .bxor => "__bxor",
        .shl => "__shl",
        .shr => "__shr",
        .bnot => "__bnot",
        else => "",
    };
}

fn floatMod(x: f64, y: f64) f64 {
    if (y == 0 or std.math.isInf(x) or std.math.isNan(x) or std.math.isNan(y)) return std.math.nan(f64);
    if (std.math.isInf(y)) return x;
    var r = @rem(x, y);
    if (r < 0) r += @abs(y);
    return r;
}

/// An integer, or a float with an integral value, as an integer.
fn exactInt(v: Value) ?i64 {
    switch (v) {
        .int => |i| return i,
        .float => |f| {
            if (f == @trunc(f) and f >= -9.2e18 and f <= 9.2e18) return @intFromFloat(f);
            return null;
        },
        else => return null,
    }
}

fn isBitOp(op: Op) bool {
    return switch (op) {
        .band, .bor, .bxor, .shl, .shr => true,
        else => false,
    };
}

/// & | ~ << >> on integers (floats with integral values convert). Shifts by
/// 64 or more give 0 (or -1 for a negative value shifted right); a negative
/// shift amount is an error, reported by arithMeta.
pub fn bitop(op: Op, x: i64, y: i64) ?Value {
    return switch (op) {
        .band => .{ .int = x & y },
        .bor => .{ .int = x | y },
        .bxor => .{ .int = x ^ y },
        .shl => blk: {
            if (y < 0) break :blk null;
            if (y >= 64) break :blk .{ .int = 0 };
            break :blk .{ .int = x << @as(u6, @intCast(y)) };
        },
        .shr => blk: {
            if (y < 0) break :blk null;
            const n: u6 = if (y >= 64) 63 else @intCast(y);
            break :blk .{ .int = x >> n };
        },
        else => unreachable,
    };
}

/// ~a for anything but an int: an integral float, or __bnot.
pub fn bnotSlow(th: *Thread, a: Value) Error!Value {
    if (exactInt(a)) |x| return .{ .int = ~x };
    const f = metamethod(a, .null, "__bnot");
    if (f == .function) return th.call(f, &.{a});
    if (a == .float) return th.vm.raiseKind("arithmetic", "number has no integer representation in bitwise operation (~)", .{});
    return th.vm.raiseKind("type", "attempt to perform bitwise operation (~) on a {s} value", .{a.typeName()});
}

/// + - * / % ^ on two integers: null for a modulo by zero (an error).
inline fn intArith(op: Op, x: i64, y: i64) ?Value {
    switch (op) {
        .add => return .{ .int = x +% y },
        .sub => return .{ .int = x -% y },
        .mul => return .{ .int = x *% y },
        .div => return .{ .float = @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y)) },
        .mod => {
            if (y == 0) return null;
            if (y == -1) return .{ .int = 0 };
            var r = @rem(x, y);
            if (r < 0) r = if (y < 0) r - y else r + y;
            return .{ .int = r };
        },
        .pow => {
            if (y >= 0) {
                var r: i64 = 1;
                var bs = x;
                var e = y;
                while (e > 0) {
                    if (e & 1 == 1) r *%= bs;
                    bs *%= bs;
                    e >>= 1;
                }
                return .{ .int = r };
            }
            return .{ .float = std.math.pow(f64, @floatFromInt(x), @floatFromInt(y)) };
        },
        else => unreachable,
    }
}

inline fn floatArith(op: Op, x: f64, y: f64) Value {
    return switch (op) {
        .add => .{ .float = x + y },
        .sub => .{ .float = x - y },
        .mul => .{ .float = x * y },
        .div => .{ .float = x / y },
        .mod => .{ .float = floatMod(x, y) },
        .pow => .{ .float = std.math.pow(f64, x, y) },
        else => unreachable,
    };
}

/// + - * / % ^ on numbers: int and int, float and float, then mixed; null
/// when an operand is not a number (or for an integer modulo by zero).
/// The opcodes call this with a comptime op, so each folds to its case.
pub inline fn numArith(op: Op, a: Value, b: Value) ?Value {
    if (a == .int and b == .int) return intArith(op, a.int, b.int);
    if (a == .float and b == .float) return floatArith(op, a.float, b.float);
    if (a.isNumber() and b.isNumber()) return floatArith(op, a.asNumber(), b.asNumber());
    return null;
}

/// A binary arithmetic operation on built-in types. Returns null when the
/// operands do not support it.
fn arith(th: *Thread, op: Op, a: Value, b: Value) ?Value {
    if (isBitOp(op)) {
        const x = exactInt(a) orelse return null;
        const y = exactInt(b) orelse return null;
        return bitop(op, x, y);
    }
    if (numArith(op, a, b)) |r| return r;
    if (a == .string) {
        switch (op) {
            .add => if (b == .string) {
                const sa = a.string.bytes();
                const sb = b.string.bytes();
                const s = th.vm.newStringUninit(sa.len + sb.len);
                const out = s.mutableBytes();
                @memcpy(out[0..sa.len], sa);
                @memcpy(out[sa.len..], sb);
                return .{ .string = s };
            },
            .mul => if (b == .int) {
                const n: usize = if (b.int < 0) 0 else @intCast(b.int);
                const sa = a.string.bytes();
                const s = th.vm.newStringUninit(sa.len * n);
                const out = s.mutableBytes();
                var i: usize = 0;
                while (i < n) : (i += 1) @memcpy(out[i * sa.len .. (i + 1) * sa.len], sa);
                return .{ .string = s };
            },
            else => {},
        }
    }
    return null;
}

pub const ThreadOps = struct {
    /// Performs a binary arithmetic operation; when the built-in operation
    /// does not apply, the operands' metamethod is called instead.
    pub fn arithMeta(th: *Thread, op: Op, a: Value, b: Value) Error!Value {
        if (arith(th, op, a, b)) |r| return r;
        if (op == .mod and a == .int and b == .int) return th.vm.raiseKind("arithmetic", "integer modulo by zero", .{});
        if (isBitOp(op) and a.isNumber() and b.isNumber()) {
            if (exactInt(a) != null and exactInt(b) != null) return th.vm.raiseKind("arithmetic", "negative shift amount", .{});
            return th.vm.raiseKind("arithmetic", "number has no integer representation in bitwise operation ({s})", .{op.symbol()});
        }
        const f = metamethod(a, b, arithMetaName(op));
        if (f == .function) return th.call(f, &.{ a, b });
        if (isBitOp(op)) {
            if (a.kind() == b.kind()) return th.vm.raiseKind("type", "attempt to perform bitwise operation ({s}) on {s} values", .{ op.symbol(), a.typeName() });
            return th.vm.raiseKind("type", "attempt to perform bitwise operation ({s}) on {s} and {s}", .{ op.symbol(), a.typeName(), b.typeName() });
        }
        return th.vm.raiseKind("type", "attempt to perform arithmetic ({s}) on {s} and {s}", .{ op.symbol(), a.typeName(), b.typeName() });
    }

    /// Indexing with __index metamethods.
    pub fn getTable(th: *Thread, obj_: Value, key: Value) Error!Value {
        var obj = obj_;
        var depth: usize = 0;
        while (depth < 100) : (depth += 1) {
            var meta: ?*Table = null;
            switch (obj) {
                .table => |t| {
                    const raw = t.get(key);
                    if (raw != .null or t.meta == null or t.has(key)) return raw;
                    meta = t.meta;
                },
                .userdata => |u| {
                    // buffers of scalars: the element, without __index
                    if (u.kind == .buffer and key == .int) {
                        if (try ctypes.fastGet(th, u, key.int)) |v| return v;
                    }
                    meta = u.meta;
                },
                .null => {
                    var buf: [256]u8 = undefined;
                    return th.vm.raiseKind("type", "attempt to index a null value (key {s})", .{keyDesc(&buf, key)});
                },
                else => return .null,
            }
            const m = meta orelse return .null;
            // a property: its getter, called with the object indexed
            // first (also when the property is inherited)
            if (hasGetter(th.vm, m, key)) {
                const g = m.getStr(th.vm.get_name).table.get(key);
                return th.call(g, &.{obj_});
            }
            const idx = m.getStr(th.vm.index_name);
            switch (idx) {
                .function => return th.call(idx, &.{ obj, key }),
                .table => obj = idx,
                else => return .null,
            }
        }
        return th.vm.raise("__index chain too long", .{});
    }

    /// A store to a property: the setter of key in the __set tables along
    /// the metatable chain (the metatable of obj, then of its __index
    /// tables); true when one ran. A key with a getter but no setter is
    /// read-only: raises.
    fn setProperty(th: *Thread, meta: *Table, obj: Value, key: Value, val: Value) Error!bool {
        const vm = th.vm;
        var m = meta;
        var depth: usize = 0;
        while (depth < 100) : (depth += 1) {
            const flags = m.metaFlags(vm.newindex_name, vm.get_name, vm.set_name);
            if (flags & Table.mf_set != 0) {
                const st = m.getStr(vm.set_name);
                if (st == .table) {
                    const f = st.table.get(key);
                    if (f != .null) {
                        _ = try th.call(f, &.{ obj, val });
                        return true;
                    }
                }
            }
            if (flags & Table.mf_get != 0 and hasGetter(vm, m, key)) {
                var buf: [256]u8 = undefined;
                return vm.raiseKind("type", "property {s} of {s} is read-only", .{ keyDesc(&buf, key), typeNameOf(obj) });
            }
            const idx = m.getStr(vm.index_name);
            if (idx != .table) return false;
            m = idx.table.meta orelse return false;
        }
        return false;
    }

    /// Assignment with __newindex metamethods.
    pub fn setTable(th: *Thread, obj_: Value, key: Value, val: Value) Error!void {
        var obj = obj_;
        var depth: usize = 0;
        while (depth < 100) : (depth += 1) {
            switch (obj) {
                .table => |t| {
                    if (key == .null) return th.vm.raiseKind("argument", "table index is null", .{});
                    const m = t.meta orelse return th.rawSet(t, key, val);
                    if (t.has(key)) return th.rawSet(t, key, val);
                    if (try ThreadOps.setProperty(th, m, obj_, key, val)) return;
                    const ni = m.getStr(th.vm.newindex_name);
                    switch (ni) {
                        .null => return th.rawSet(t, key, val),
                        .function => {
                            _ = try th.call(ni, &.{ obj, key, val });
                            return;
                        },
                        .table => obj = ni,
                        else => return,
                    }
                },
                .userdata => |u| {
                    if (u.kind == .buffer and key == .int) {
                        if (try ctypes.fastSet(th, u, key.int, val)) return;
                    }
                    if (u.meta) |m| {
                        if (try ThreadOps.setProperty(th, m, obj_, key, val)) return;
                        const ni = m.getStr(th.vm.newindex_name);
                        switch (ni) {
                            .function => {
                                _ = try th.call(ni, &.{ obj, key, val });
                                return;
                            },
                            .table => {
                                obj = ni;
                                continue;
                            },
                            .null => {},
                            else => return,
                        }
                    }
                    return th.vm.raiseKind("type", "cannot set value on userdata", .{});
                },
                .null => {
                    var buf: [256]u8 = undefined;
                    return th.vm.raiseKind("type", "attempt to index a null value (key {s})", .{keyDesc(&buf, key)});
                },
                else => {
                    var buf: [256]u8 = undefined;
                    return th.vm.raiseKind("type", "attempt to index a {s} value (key {s})", .{ obj.typeName(), keyDesc(&buf, key) });
                },
            }
        }
        return th.vm.raise("__newindex chain too long", .{});
    }

    /// slang's ==: numbers across int and float, __eq for tables and
    /// userdata (which may run slang code), structural otherwise.
    pub fn equal(th: *Thread, a: Value, b: Value) Error!bool {
        if (a == .int and b == .int) return a.int == b.int;
        return compareSlow(th, .eq, a, b);
    }

    /// slang's <: numbers, __lt, or the comparison error.
    pub fn lessThan(th: *Thread, a: Value, b: Value) Error!bool {
        if (a == .int and b == .int) return a.int < b.int;
        return compareSlow(th, .lt, a, b);
    }

    /// x.@meta = m: a table's metatable is a table or null; other values'
    /// metatables are not slang's to set
    pub fn setMeta(th: *Thread, obj: Value, m: Value) Error!void {
        const t = obj.asTable() orelse return th.vm.raiseKind("type", "cannot set the metatable of a {s} value", .{obj.typeName()});
        switch (m) {
            .table => |mt| {
                t.setMetatable(th.vm.gpa, mt);
                gc.barrier(th.vm, &t.obj, m);
            },
            .null => t.setMetatable(th.vm.gpa, null),
            else => return th.vm.raiseKind("type", "@meta must be a table or null, got {s}", .{m.typeName()}),
        }
    }

    pub fn rawSet(th: *Thread, t: *Table, key: Value, val: Value) Error!void {
        t.set(th.vm.gpa, key, val);
    }

    /// The type operation including the __type metafield.
    pub fn typeOf(th: *Thread, v: Value) Error!Value {
        var meta: ?*Table = null;
        var def: []const u8 = undefined;
        switch (v) {
            .table => |t| {
                meta = t.meta;
                def = "table";
            },
            .userdata => |u| {
                meta = u.meta;
                def = "userdata";
            },
            else => return th.vm.str(v.typeName()),
        }
        if (meta) |m| {
            const ty = m.getName("__type");
            switch (ty) {
                .null => {},
                .function => return th.call(ty, &.{v}),
                else => return ty,
            }
        }
        return th.vm.str(def);
    }

    /// Converts v to its display string, through __tostring if the value has
    /// one.
    pub fn toString(th: *Thread, v: Value) Error!*String {
        if (metaOf(v)) |m| {
            const f = m.getName("__tostring");
            if (f == .function) {
                const r = try th.call(f, &.{v});
                return th.renderString(r);
            }
        }
        return th.renderString(v);
    }

    /// Renders v without metamethods.
    pub fn renderString(th: *Thread, v: Value) *String {
        switch (v) {
            .string => |s| return s,
            .int, .float, .bool, .null => {
                var buf: [48]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                root.format.writeValue(&w, v) catch unreachable;
                return th.vm.newString(w.buffered());
            },
            else => {
                const bytes = root.format.valueToOwned(th.vm.gpa, v);
                defer th.vm.gpa.free(bytes);
                return th.vm.newString(bytes);
            },
        }
    }

    /// len: the length of a string or table, or __len.
    pub fn len(th: *Thread, v: Value) Error!Value {
        if (metaOf(v)) |m| {
            const f = m.getName("__len");
            if (f == .function) return th.call(f, &.{v});
        }
        return switch (v) {
            // the list: 0, 1, 2, ... up to the first missing index
            .table => |t| .{ .int = @intCast(t.arrayLen()) },
            .string => |s| .{ .int = @intCast(s.len) },
            else => th.vm.raiseKind("type", "len requires a table or string", .{}),
        };
    }
};

test "putRaw writes the layout of a tagged union (payload, then the tag)" {
    var v: Value = .null;
    putRaw(&v, .float, @bitCast(@as(f64, 1.5)));
    try std.testing.expect(v == .float and v.float == 1.5);
    putRaw(&v, .int, @bitCast(@as(i64, -3)));
    try std.testing.expect(v == .int and v.int == -3);
    putRaw(&v, .bool, 1);
    try std.testing.expect(v == .bool and v.bool);
}
