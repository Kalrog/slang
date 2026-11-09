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
const d = @import("disasm.zig");
const Op = d.Op;
const Ic = @import("table.zig").Ic;
const interp_reg = @import("interp_reg.zig");

// ---- inline caches (quickening)
//
// The first time a get_x, self_x or set_x with a constant string key runs,
// it is rewritten in place into get_k, self_k or set_k, whose key operand
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

/// Where a quickened instruction keeps its key: get_x and self_x in C,
/// set_x in B.
fn keyField(comptime op: Op) u5 {
    return if (op == .set_x) 23 else 14;
}

/// The key of a get_x, self_x or set_x that can be quickened: a constant
/// string (for a store not a metamethod name: those change what the caches
/// depend on, and not a literal's field), the instruction not quickened
/// already (after a miss it runs as itself), room for another cache in the
/// prototype (9 bits).
inline fn quickenable(proto: *root.Proto, code: []u32, consts: []const Value, pc: usize, ins: u32, comptime op: Op) ?*String {
    const x = (ins >> keyField(op)) & 0x1FF;
    if (x < d.first_constant or x >= d.first_upvalue) return null;
    const k = consts[x - d.first_constant];
    if (k != .string) return null;
    if (d.opOf(code[pc - 1]) != op) return null;
    if (proto.ics.items.len >= d.stack_operand) return null;
    if (op == .set_x) {
        // a table literal's field (into the table on top): always a new
        // key, which the cache does not store
        if (d.argA(ins) == d.peek_dest) return null;
        const b = k.string.bytes();
        if (b.len >= 2 and b[0] == '_' and b[1] == '_') return null;
    }
    return k.string;
}

/// Gives the instruction a cache and rewrites it at pc - 1 into its
/// quickened form, which it returns.
fn quicken(vm: *root.VM, proto: *root.Proto, code: []u32, pc: usize, ins: u32, key: *String, comptime op: Op) u32 {
    const idx: u32 = @intCast(proto.ics.items.len);
    proto.ics.append(vm.gpa, .{ .key = key, .orig = ins, .keybit = Table.keyBit(key) }) catch oom();
    const q: Op = switch (op) {
        .get_x => .get_k,
        .self_x => .self_k,
        .set_x => .set_k,
        else => unreachable,
    };
    const shift = comptime keyField(op);
    const quick = (ins & ~((@as(u32, 0x1FF) << shift) | 0x3F)) | (idx << shift) | @intFromEnum(q);
    code[pc - 1] = quick;
    return quick;
}

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

/// == of a jeq without a call: null, booleans and strings (whose __eq is
/// never asked). Null: numbers of mixed kinds, tables, the rest.
pub inline fn eqInline(a: Value, b: Value) ?bool {
    if (a == .null or b == .null) return a == .null and b == .null;
    if (a == .string and b == .string) return a.string.eql(b.string);
    if (a == .bool and b == .bool) return a.bool == b.bool;
    return null;
}

/// Executes frames until the frame depth drops back to stop_depth.
///
/// The stack top and the stack base pointer live in locals while a frame
/// runs: `th.top` is written back, and both are reloaded (a call may grow
/// the stack), around everything that calls out: natives, metamethods, the
/// collector, error handling and the trace.
///
/// There is a loop for each ISA (this one for the stack ISA, interp_reg.zig
/// for the register ISA); each runs the frames of its own and returns here
/// when a call or a return reaches a frame of the other one.
pub fn run(th: *Thread, stop_depth: usize) Error!void {
    th.run_depth += 1;
    defer th.run_depth -= 1;
    // the trace check costs about 3% on call-heavy code when it sits in
    // every opcode, so each loop exists twice: with and without it (the
    // profiler and the debugger use the same hook)
    const vm = th.vm;
    const trace = vm.tracer != null or vm.opstats != null or vm.profiler != null or vm.debugger != null;
    while (th.frames.items.len > stop_depth) {
        const p = th.frames.items[th.frames.items.len - 1].cl.proto orelse return vm.raise("internal error: native frame in interpreter loop", .{});
        switch (p.isa) {
            .stack => if (trace) try runImpl(th, stop_depth, true) else try runImpl(th, stop_depth, false),
            .register => if (trace) try interp_reg.run(th, stop_depth, true) else try interp_reg.run(th, stop_depth, false),
        }
    }
}

fn runImpl(th: *Thread, stop_depth: usize, comptime trace: bool) Error!void {
    const vm = th.vm;
    outer: while (true) {
        const n = th.frames.items.len;
        if (n <= stop_depth) return;
        var fi = n - 1;
        const frame = th.frames.items[fi];
        var proto = frame.cl.proto orelse return vm.raise("internal error: native frame in interpreter loop", .{});
        // a frame of the register ISA: back to run
        if (proto.isa != .stack) return;
        var code = proto.code;
        var consts = proto.consts;
        var base: usize = frame.base;
        var pc: usize = frame.pc;
        var top: usize = th.top;
        var stack: [*]Value = th.stack.ptr;
        var ins: u32 = undefined;
        // labelled switch: every opcode fetches the next instruction and
        // jumps straight to its case
        sw: switch (fetch(trace, th, code, fi, base, &pc, top, &ins)) {
            .load_constant => {
                stack[top] = consts[d.argBx(ins)];
                top += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .load_bool => {
                stack[top] = .{ .bool = d.argB(ins) != 0 };
                top += 1;
                if (d.argC(ins) != 0) pc += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .load_closure => {
                th.top = top;
                gc.safePoint(vm, th) catch |e| {
                    spill(trace, th, fi, pc, top);
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                const cl = th.makeClosure(th.frames.items[fi], proto.children[d.argAx(ins)]);
                stack[top] = .{ .function = cl };
                top += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            inline .add, .sub, .mul, .div, .mod => |op| {
                const b = stack[top - 1];
                const a = stack[top - 2];
                if (numArith(op, a, b)) |r| {
                    top -= 1;
                    stack[top - 1] = r;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                // operands stay on the stack during the (possibly
                // allocating) operation so the collector can see them
                spill(trace, th, fi, pc, top);
                const r = th.arithMeta(op, a, b) catch |e| {
                    th.top -= 2;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top - 1;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .pow, .band, .bor, .bxor, .shl, .shr => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                spill(trace, th, fi, pc, top);
                const r = th.arithMeta(d.opOf(ins), a, b) catch |e| {
                    th.top -= 2;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top - 1;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .neg => {
                const a = stack[top - 1];
                switch (a) {
                    .int => |i| stack[top - 1] = .{ .int = 0 -% i },
                    .float => |f| stack[top - 1] = .{ .float = -f },
                    else => {
                        spill(trace, th, fi, pc, top);
                        const f = metamethod(a, .null, "__unm");
                        if (f == .function) {
                            const r = th.call(f, &.{a}) catch |e| {
                                try th.handleError(e, stop_depth);
                                continue :outer;
                            };
                            top = th.top;
                            stack = th.stack.ptr;
                            stack[top - 1] = r;
                            continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                        }
                        vm.setError("attempt to negate a {s} value", .{a.typeName()});
                        try th.handleError(error.Slang, stop_depth);
                        continue :outer;
                    },
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .bnot => {
                const a = stack[top - 1];
                if (a == .int) {
                    stack[top - 1] = .{ .int = ~a.int };
                } else {
                    spill(trace, th, fi, pc, top);
                    const r = bnotSlow(th, a) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    top = th.top;
                    stack = th.stack.ptr;
                    stack[top - 1] = r;
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .not => {
                // Read into a local first: writing `.{ .bool = ... }` straight
                // into the slot sets the tag before the operand is evaluated
                // (Zig result-location semantics).
                const v = stack[top - 1];
                stack[top - 1] = .{ .bool = !v.truthy() };
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .eq => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                top -= 1;
                if (a == .int and b == .int) {
                    const r = a.int == b.int;
                    stack[top - 1] = .{ .bool = r };
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                if (a == .float and b == .float) {
                    const r = a.float == b.float;
                    stack[top - 1] = .{ .bool = r };
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                if (a.kind() == b.kind() and (a == .table or a == .userdata)) {
                    const f = metamethod(a, b, "__eq");
                    if (f == .function) {
                        spill(trace, th, fi, pc, top);
                        const r = th.call(f, &.{ a, b }) catch |e| {
                            th.top -= 1;
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        top = th.top;
                        stack = th.stack.ptr;
                        stack[top - 1] = .{ .bool = r.truthy() };
                        continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                    }
                }
                stack[top - 1] = .{ .bool = a.equals(b) };
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .lt, .leq => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                top -= 1;
                const is_lt = d.opOf(ins) == .lt;
                var r: bool = undefined;
                if (a == .int and b == .int) {
                    r = if (is_lt) a.int < b.int else a.int <= b.int;
                } else if (a.isNumber() and b.isNumber()) {
                    const x = a.asNumber();
                    const y = b.asNumber();
                    r = if (is_lt) x < y else x <= y;
                } else {
                    spill(trace, th, fi, pc, top);
                    const name: []const u8 = if (is_lt) "__lt" else "__le";
                    const f = metamethod(a, b, name);
                    if (f == .function) {
                        const res = th.call(f, &.{ a, b }) catch |e| {
                            th.top -= 1;
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        top = th.top;
                        stack = th.stack.ptr;
                        stack[top - 1] = .{ .bool = res.truthy() };
                        continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                    }
                    th.top -= 1;
                    vm.setError("attempt to compare {s} {s} {s}", .{ a.typeName(), if (is_lt) "<" else "<=", b.typeName() });
                    try th.handleError(error.Slang, stop_depth);
                    continue :outer;
                }
                stack[top - 1] = .{ .bool = r };
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .move => {
                const v = stack[top - 1];
                top -= 1;
                stack[absIndex(top, base, d.argSBx(ins))] = v;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .push => {
                stack[top] = stack[absIndex(top, base, d.argSBx(ins))];
                top += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .pop => {
                const keep: usize = d.argA(ins);
                const drop: usize = d.argBx(ins);
                if (keep > 0) {
                    std.mem.copyForwards(Value, stack[top - drop - keep .. top - drop], stack[top - keep .. top]);
                }
                top -= drop;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .@"return" => {
                const res = stack[top - 1];
                const fn_idx = base - 1;
                const dest = th.frames.items[fi].dest;
                th.top = top;
                th.popFrame();
                th.top = fn_idx;
                if (dest == thread_mod.dest_push) {
                    th.stack[fn_idx] = res;
                    th.top = fn_idx + 1;
                } else if (dest != thread_mod.dest_drop) {
                    // a getter's result, into its caller's register
                    th.stack[th.frames.items[th.frames.items.len - 1].base + dest] = res;
                }
                if (th.frames.items.len == stop_depth) return;
                // the caller's frame, without leaving the switch (every
                // frame above stop_depth is a slang frame: natives that
                // call back run their own loop)
                fi = th.frames.items.len - 1;
                const fr = th.frames.items[fi];
                proto = fr.cl.proto.?;
                if (proto.isa != .stack) continue :outer;
                code = proto.code;
                consts = proto.consts;
                base = fr.base;
                pc = fr.pc;
                top = th.top;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .new_table => {
                th.top = top;
                gc.safePoint(vm, th) catch |e| {
                    spill(trace, th, fi, pc, top);
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack[top] = .{ .table = vm.newTable(d.argB(ins), d.argC(ins)) };
                top += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .set_table => {
                const val = stack[top - 1];
                const key = stack[top - 2];
                const obj = stack[top - 3];
                top -= 3;
                if (setFast(vm, obj, key, val)) continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                if (findSetter(vm, obj, key)) |f| {
                    // a property: its setter, called as a call, its result
                    // dropped
                    stack[top] = f;
                    stack[top + 1] = obj;
                    stack[top + 2] = val;
                    spill(trace, th, fi, pc, top + 3);
                    const is_slang = th.precall(top, 2) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    const acc_dest: u16 = thread_mod.dest_drop;
                    if (is_slang) {
                        th.frames.items[th.frames.items.len - 1].dest = acc_dest;
                        fi = th.frames.items.len - 1;
                        const fr = th.frames.items[fi];
                        proto = fr.cl.proto.?;
                        if (proto.isa != .stack) continue :outer;
                        code = proto.code;
                        consts = proto.consts;
                        base = fr.base;
                        pc = fr.pc;
                        top = th.top;
                        stack = th.stack.ptr;
                    } else {
                        // a native accessor ran already: its result where it was
                        top = th.top;
                        stack = th.stack.ptr;
                        if (acc_dest != thread_mod.dest_push) {
                            top -= 1;
                            if (acc_dest != thread_mod.dest_drop) stack[base + acc_dest] = stack[top];
                        }
                    }
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                spill(trace, th, fi, pc, top);
                th.setTable(obj, key, val) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .get_table => {
                const key = stack[top - 1];
                const obj = stack[top - 2];
                top -= 1;
                var getter: Value = .null;
                if (getFastG(vm, obj, key, &getter)) |v| {
                    stack[top - 1] = v;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                top -= 1;
                if (getter != .null) {
                    const g = getter;
                    // a property: its getter, called as a call instruction
                    // calls (the result lands where obj was)
                    stack[top] = g;
                    stack[top + 1] = obj;
                    spill(trace, th, fi, pc, top + 2);
                    const is_slang = th.precall(top, 1) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    if (is_slang) {
                        fi = th.frames.items.len - 1;
                        const fr = th.frames.items[fi];
                        proto = fr.cl.proto.?;
                        if (proto.isa != .stack) continue :outer;
                        code = proto.code;
                        consts = proto.consts;
                        base = fr.base;
                        pc = fr.pc;
                    }
                    top = th.top;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                spill(trace, th, fi, pc, top);
                const v = th.getTable(obj, key) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                stack[top] = v;
                top += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .set_upvalue => {
                const v = stack[top - 1];
                top -= 1;
                const u = th.frames.items[fi].cl.upvals[d.argAx(ins)];
                u.set(v);
                // a closed upvalue is an object of its own (open, the value
                // is on a stack: rescanned)
                if (u.th == null) gc.barrier(th.vm, &u.obj, v);
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .get_upvalue => {
                stack[top] = th.frames.items[fi].cl.upvals[d.argAx(ins)].get();
                top += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .close_upvalues => {
                th.closeUpvalues(base + d.argAx(ins));
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .@"test" => {
                const v = stack[top - 1];
                top -= 1;
                if (v.truthy() != (d.argC(ins) != 0)) pc += 1;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .jump => {
                const off = d.argSBx(ins);
                if (off < 0) {
                    spill(trace, th, fi, pc, top);
                    gc.safePoint(vm, th) catch |e| {
                        spill(trace, th, fi, pc, top);
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                }
                pc = @intCast(@as(i64, @intCast(pc)) + off);
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .call_spread => {
                spill(trace, th, fi, pc, top);
                gc.safePoint(vm, th) catch |e| {
                    spill(trace, th, fi, pc, top);
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                const fixed: usize = d.argBx(ins);
                const list = stack[top - 1];
                if (list != .table) {
                    vm.setError("attempt to spread a {s} value", .{list.typeName()});
                    try th.handleError(error.Slang, stop_depth);
                    continue :outer;
                }
                // every index up to the largest: a gap is passed as null,
                // so ...args forwards f(1, null, 3) as it came
                const lt = list.table;
                const spread_n = lt.spreadLen();
                top -= 1;
                spill(trace, th, fi, pc, top);
                th.ensure(top + spread_n + 8) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                for (0..spread_n) |i| {
                    stack[top] = lt.getInt(@intCast(i));
                    top += 1;
                }
                spill(trace, th, fi, pc, top);
                const nargs = fixed + spread_n;
                const fn_idx = top - nargs - 1;
                const is_slang = th.precall(fn_idx, nargs) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                if (is_slang) {
                    // the callee's frame, without leaving the switch
                    fi = th.frames.items.len - 1;
                    const fr = th.frames.items[fi];
                    proto = fr.cl.proto.?;
                    if (proto.isa != .stack) continue :outer;
                    code = proto.code;
                    consts = proto.consts;
                    base = fr.base;
                    pc = fr.pc;
                    top = th.top;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                top = th.top;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .forin_prep => {
                // [f, x]: the built-in keys, values or entries of a table
                // become a walk of the table in the loop (forin_next) with
                // nothing allocated; anything else is the call f(x)
                const f = stack[top - 2];
                const x = stack[top - 1];
                if (f == .function and x == .table) {
                    if (iterKind(f.function)) |kind| {
                        stack[top - 2] = x;
                        top -= 1;
                        stack[base + d.argA(ins)] = .{ .int = kind };
                        continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                    }
                }
                ins = @as(u32, 1) << 14 | @intFromEnum(Op.call);
                continue :sw .call;
            },
            .forin_next => {
                const it = stack[top - 1];
                if (it == .table) {
                    const ra = base + d.argA(ins);
                    var state: u64 = @intCast(stack[ra].int);
                    const e = it.table.nextLive(&state);
                    if (e) |entry| {
                        stack[ra] = .{ .int = @intCast(state) };
                        const v: Value = switch (state & 3) {
                            0 => entry.key,
                            1 => entry.val,
                            else => .{ .table = corelib.entryPair(vm, entry) },
                        };
                        stack[top] = v;
                        top += 1;
                        // the second word: to the pattern
                        const off = d.argSBx(code[pc + 1]);
                        pc += 2 + @as(usize, @intCast(off));
                    } else {
                        // the end: the loop's stop path pops a value
                        stack[top] = .null;
                        top += 1;
                        const off = d.argSBx(code[pc]);
                        pc += 1 + @as(usize, @intCast(off));
                    }
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                // an iterator function: the call after the two words
                pc += 2;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .call => {
                spill(trace, th, fi, pc, top);
                gc.safePoint(vm, th) catch |e| {
                    spill(trace, th, fi, pc, top);
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                const nargs: usize = d.argBx(ins);
                const fn_idx = top - nargs - 1;
                const is_slang = th.precall(fn_idx, nargs) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                if (is_slang) {
                    // the callee's frame, without leaving the switch
                    fi = th.frames.items.len - 1;
                    const fr = th.frames.items[fi];
                    proto = fr.cl.proto.?;
                    if (proto.isa != .stack) continue :outer;
                    code = proto.code;
                    consts = proto.consts;
                    base = fr.base;
                    pc = fr.pc;
                    top = th.top;
                    stack = th.stack.ptr;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                top = th.top;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .type => {
                const v = stack[top - 1];
                spill(trace, th, fi, pc, top);
                const r = th.typeOf(v) catch |e| {
                    th.top -= 1;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .try_begin => {
                const off = d.argSBx(ins);
                th.pushHandler(.{
                    .frame = @intCast(fi),
                    .pc = @intCast(@as(i64, @intCast(pc)) + off),
                    .top = @intCast(top),
                    .close_from = @intCast(base + d.argA(ins)),
                });
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .try_end => {
                _ = th.handlers.pop();
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .throw => {
                const v = stack[top - 1];
                spill(trace, th, fi, pc, top - 1);
                vm.setErrorFromValue(v);
                try th.handleError(error.Slang, stop_depth);
                continue :outer;
            },
            .get_meta => {
                const v = stack[top - 1];
                stack[top - 1] = switch (v) {
                    .table => |t| Value.fromTable(t.meta),
                    .userdata => |u| Value.fromTable(u.meta),
                    else => .null,
                };
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .set_meta => {
                const m = stack[top - 1];
                const obj = stack[top - 2];
                top -= 2;
                th.setMeta(obj, m) catch |e| {
                    spill(trace, th, fi, pc, top);
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            // ---- the fused forms (see disasm.zig): each does what its core
            // sequence does, with the same errors at the same location
            inline .add_x, .sub_x, .mul_x, .div_x, .mod_x => |op| {
                const core = comptime d.coreOf(op);
                const bx = d.argB(ins);
                const b = operandValue(th, fi, stack, base, consts, d.argC(ins));
                const popped: usize = @intFromBool(bx == d.stack_operand);
                const a = if (popped != 0) stack[top - 1] else operandValue(th, fi, stack, base, consts, bx);
                if (numArith(core, a, b)) |r| {
                    top -= popped;
                    storeDest(stack, base, &top, d.argA(ins), r);
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                // a popped operand stays on the stack during the operation
                spill(trace, th, fi, pc, top);
                const r = th.arithMeta(core, a, b) catch |e| {
                    th.top -= popped;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top - popped;
                stack = th.stack.ptr;
                storeDest(stack, base, &top, d.argA(ins), r);
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            inline .jlt, .jleq, .jeq => |op| {
                const core = comptime d.coreOf(op);
                const bx = d.argB(ins);
                const b = operandValue(th, fi, stack, base, consts, d.argC(ins));
                const popped: usize = @intFromBool(bx == d.stack_operand);
                const a = if (popped != 0) stack[top - 1] else operandValue(th, fi, stack, base, consts, bx);
                var r: bool = undefined;
                if (a == .int and b == .int) {
                    r = switch (core) {
                        .lt => a.int < b.int,
                        .leq => a.int <= b.int,
                        else => a.int == b.int,
                    };
                } else if (a == .float and b == .float) {
                    r = switch (core) {
                        .lt => a.float < b.float,
                        .leq => a.float <= b.float,
                        else => a.float == b.float,
                    };
                } else if (if (core == .eq) eqInline(a, b) else null) |e| {
                    r = e;
                } else {
                    spill(trace, th, fi, pc, top);
                    r = compareSlow(th, core, a, b) catch |e| {
                        th.top -= popped;
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    top = th.top;
                    stack = th.stack.ptr;
                }
                top -= popped;
                if (r != (d.argA(ins) != 0)) {
                    pc += 1;
                } else {
                    // the jump that follows, taken here when it goes
                    // forward (a backward one runs as itself: safe point)
                    const off = d.argSBx(code[pc]);
                    if (off >= 0) pc += 1 + @as(usize, @intCast(off));
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .jtest => {
                const v = operandValue(th, fi, stack, base, consts, d.argB(ins));
                if (v.truthy() != (d.argA(ins) != 0)) {
                    pc += 1;
                } else {
                    const off = d.argSBx(code[pc]);
                    if (off >= 0) pc += 1 + @as(usize, @intCast(off));
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .get_x => {
                quicken: {
                    const k = quickenable(proto, code, consts, pc, ins, .get_x) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, k, .get_x);
                    continue :sw .get_k;
                }
                const bx = d.argB(ins);
                const key = operandValue(th, fi, stack, base, consts, d.argC(ins));
                const popped: usize = @intFromBool(bx == d.stack_operand);
                const obj = if (popped != 0) stack[top - 1] else operandValue(th, fi, stack, base, consts, bx);
                top -= popped;
                var getter: Value = .null;
                if (getFastG(vm, obj, key, &getter)) |v| {
                    storeDest(stack, base, &top, d.argA(ins), v);
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                if (getter != .null) {
                    const g = getter;
                    // a property: its getter as a call, the result pushed
                    // or put in the register A
                    const a = d.argA(ins);
                    th.top = top;
                    th.ensure(top + 2) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    stack = th.stack.ptr;
                    stack[top] = g;
                    stack[top + 1] = obj;
                    const dest: u16 = if (a == d.push_dest) thread_mod.dest_push else @intCast(a);
                    spill(trace, th, fi, pc, top + 2);
                    const is_slang = th.precall(top, 1) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    const acc_dest: u16 = dest;
                    if (is_slang) {
                        th.frames.items[th.frames.items.len - 1].dest = acc_dest;
                        fi = th.frames.items.len - 1;
                        const fr = th.frames.items[fi];
                        proto = fr.cl.proto.?;
                        if (proto.isa != .stack) continue :outer;
                        code = proto.code;
                        consts = proto.consts;
                        base = fr.base;
                        pc = fr.pc;
                        top = th.top;
                        stack = th.stack.ptr;
                    } else {
                        // a native accessor ran already: its result where it was
                        top = th.top;
                        stack = th.stack.ptr;
                        if (acc_dest != thread_mod.dest_push) {
                            top -= 1;
                            if (acc_dest != thread_mod.dest_drop) stack[base + acc_dest] = stack[top];
                        }
                    }
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                spill(trace, th, fi, pc, top);
                const v = th.getTable(obj, key) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                storeDest(stack, base, &top, d.argA(ins), v);
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .set_k => {
                const ic = &proto.ics.items[d.argB(ins)];
                const val = operandValue(th, fi, stack, base, consts, d.argC(ins));
                const ax = d.argA(ins);
                const obj = switch (ax) {
                    d.push_dest, d.peek_dest => stack[top - 1],
                    else => stack[base + ax],
                };
                if (icStore(vm, ic, obj, val)) {
                    if (ax == d.push_dest) top -= 1;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                ins = ic.orig;
                continue :sw .set_x;
            },
            .set_x => {
                quicken: {
                    const k = quickenable(proto, code, consts, pc, ins, .set_x) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, k, .set_x);
                    continue :sw .set_k;
                }
                const val = operandValue(th, fi, stack, base, consts, d.argC(ins));
                const bx = d.argB(ins);
                var popped: usize = 0;
                var key: Value = undefined;
                if (bx == d.stack_operand) {
                    key = stack[top - 1];
                    popped = 1;
                } else {
                    key = operandValue(th, fi, stack, base, consts, bx);
                }
                const ax = d.argA(ins);
                var obj: Value = undefined;
                switch (ax) {
                    d.push_dest => {
                        obj = stack[top - 1 - popped];
                        popped += 1;
                    },
                    d.peek_dest => obj = stack[top - 1 - popped],
                    else => obj = stack[base + ax],
                }
                top -= popped;
                if (setFast(vm, obj, key, val)) continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                if (findSetter(vm, obj, key)) |f| {
                    th.top = top;
                    th.ensure(top + 3) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    stack = th.stack.ptr;
                    stack[top] = f;
                    stack[top + 1] = obj;
                    stack[top + 2] = val;
                    spill(trace, th, fi, pc, top + 3);
                    const is_slang = th.precall(top, 2) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    const acc_dest: u16 = thread_mod.dest_drop;
                    if (is_slang) {
                        th.frames.items[th.frames.items.len - 1].dest = acc_dest;
                        fi = th.frames.items.len - 1;
                        const fr = th.frames.items[fi];
                        proto = fr.cl.proto.?;
                        if (proto.isa != .stack) continue :outer;
                        code = proto.code;
                        consts = proto.consts;
                        base = fr.base;
                        pc = fr.pc;
                        top = th.top;
                        stack = th.stack.ptr;
                    } else {
                        // a native accessor ran already: its result where it was
                        top = th.top;
                        stack = th.stack.ptr;
                        if (acc_dest != thread_mod.dest_push) {
                            top -= 1;
                            if (acc_dest != thread_mod.dest_drop) stack[base + acc_dest] = stack[top];
                        }
                    }
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                spill(trace, th, fi, pc, top);
                th.setTable(obj, key, val) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .move_x => {
                stack[base + d.argA(ins)] = operandValue(th, fi, stack, base, consts, d.argB(ins));
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .get_k => {
                const ic = &proto.ics.items[d.argC(ins)];
                const bx = d.argB(ins);
                const popped: usize = @intFromBool(bx == d.stack_operand);
                const obj = if (popped != 0) stack[top - 1] else operandValue(th, fi, stack, base, consts, bx);
                var getter: Value = .null;
                if (icGet(vm, ic, obj, &getter)) |v| {
                    top -= popped;
                    storeDest(stack, base, &top, d.argA(ins), v);
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                if (getter != .null) {
                    top -= popped;
                    const g = getter;
                    // a property: its getter as a call, the result pushed
                    // or put in the register A
                    const a = d.argA(ins);
                    th.top = top;
                    th.ensure(top + 2) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    stack = th.stack.ptr;
                    stack[top] = g;
                    stack[top + 1] = obj;
                    const dest: u16 = if (a == d.push_dest) thread_mod.dest_push else @intCast(a);
                    spill(trace, th, fi, pc, top + 2);
                    const is_slang = th.precall(top, 1) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    const acc_dest: u16 = dest;
                    if (is_slang) {
                        th.frames.items[th.frames.items.len - 1].dest = acc_dest;
                        fi = th.frames.items.len - 1;
                        const fr = th.frames.items[fi];
                        proto = fr.cl.proto.?;
                        if (proto.isa != .stack) continue :outer;
                        code = proto.code;
                        consts = proto.consts;
                        base = fr.base;
                        pc = fr.pc;
                        top = th.top;
                        stack = th.stack.ptr;
                    } else {
                        // a native accessor ran already: its result where it was
                        top = th.top;
                        stack = th.stack.ptr;
                        if (acc_dest != thread_mod.dest_push) {
                            top -= 1;
                            if (acc_dest != thread_mod.dest_drop) stack[base + acc_dest] = stack[top];
                        }
                    }
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                ins = ic.orig;
                continue :sw .get_x;
            },
            .self_k => {
                const ic = &proto.ics.items[d.argC(ins)];
                const bx = d.argB(ins);
                const obj = if (bx == d.stack_operand) stack[top - 1] else operandValue(th, fi, stack, base, consts, bx);
                var getter: Value = .null;
                if (icGet(vm, ic, obj, &getter)) |f| {
                    if (bx != d.stack_operand) {
                        stack[top] = obj;
                        top += 1;
                    }
                    stack[top] = f;
                    stack[top + 1] = obj;
                    top += 2;
                    continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
                }
                ins = ic.orig;
                continue :sw .self_x;
            },
            .self_x => {
                // obj -> obj, obj[key], obj (a method call's receiver, the
                // method, the receiver as its first argument)
                quicken: {
                    const k = quickenable(proto, code, consts, pc, ins, .self_x) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, k, .self_x);
                    continue :sw .self_k;
                }
                const bx = d.argB(ins);
                const key = operandValue(th, fi, stack, base, consts, d.argC(ins));
                var obj: Value = undefined;
                if (bx == d.stack_operand) {
                    obj = stack[top - 1];
                } else {
                    obj = operandValue(th, fi, stack, base, consts, bx);
                    stack[top] = obj;
                    top += 1;
                }
                var f: Value = undefined;
                if (getFast(vm, obj, key)) |v| {
                    f = v;
                } else {
                    spill(trace, th, fi, pc, top);
                    f = th.getTable(obj, key) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    top = th.top;
                    stack = th.stack.ptr;
                }
                stack[top] = f;
                stack[top + 1] = obj;
                top += 2;
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            .for_loop => {
                // the update and the condition of a numeric for; the jump
                // word after it goes to the body and carries the flags
                const ra = base + d.argA(ins);
                const step = operandValue(th, fi, stack, base, consts, d.argB(ins));
                const limit = operandValue(th, fi, stack, base, consts, d.argC(ins));
                const j = code[pc];
                const flags = d.argA(j);
                const is_sub = flags & d.for_flags.sub != 0;
                const i = stack[ra];
                // the jump's offset from the word after it: the body, or
                // the condition (two before the body) to compare in full
                var off: i64 = d.argSBx(j);
                var cont = true;
                if (i == .int and step == .int and limit == .int) {
                    const k = if (is_sub) i.int -% step.int else i.int +% step.int;
                    stack[ra] = .{ .int = k };
                    const c = if (flags & d.for_flags.leq != 0) k <= limit.int else k < limit.int;
                    cont = c != (flags & d.for_flags.negate != 0);
                } else {
                    const r = (if (is_sub) numArith(.sub, i, step) else numArith(.add, i, step)) orelse slow: {
                        spill(trace, th, fi, pc, top);
                        const r = th.arithMeta(if (is_sub) .sub else .add, i, step) catch |e| {
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        top = th.top;
                        stack = th.stack.ptr;
                        break :slow r;
                    };
                    stack[ra] = r;
                    if (r.isNumber() and limit.isNumber()) {
                        const x = r.asNumber();
                        const y = limit.asNumber();
                        const c = if (flags & d.for_flags.leq != 0) x <= y else x < y;
                        cont = c != (flags & d.for_flags.negate != 0);
                    } else {
                        off -= 2;
                    }
                }
                if (cont) {
                    spill(trace, th, fi, pc, top);
                    gc.safePoint(vm, th) catch |e| {
                        spill(trace, th, fi, pc, top);
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    pc = @intCast(@as(i64, @intCast(pc)) + 1 + off);
                } else {
                    pc += 1;
                }
                continue :sw fetch(trace, th, code, fi, base, &pc, top, &ins);
            },
            _ => {
                spill(trace, th, fi, pc, top);
                return vm.raise("unknown opcode {d}", .{ins & 0x3F});
            },
        }
    }
}

/// Fetches the next instruction and returns its opcode. The trace build
/// (profiler, debugger, SLANG_TRACE) also runs the hook and keeps the
/// frame's pc current at every instruction.
inline fn fetch(comptime trace: bool, th: *Thread, code: []const u32, fi: usize, base: usize, pc: *usize, top: usize, ins: *u32) Op {
    ins.* = code[pc.*];
    if (trace) {
        th.top = top;
        traceInstruction(th, fi, base, pc.*, ins.*);
    }
    pc.* += 1;
    if (trace) th.frames.items[fi].pc = @intCast(pc.*);
    return d.opOf(ins.*);
}

/// Before anything that can raise, call, yield or collect: the thread's
/// top and the frame's pc (which error locations, tracebacks and the
/// return from a call read) are stored. The hot opcodes skip this.
inline fn spill(comptime trace: bool, th: *Thread, fi: usize, pc: usize, top: usize) void {
    th.top = top;
    if (!trace) th.frames.items[fi].pc = @intCast(pc);
}

pub fn traceInstruction(th: *Thread, fi: usize, base: usize, pc: usize, ins: u32) void {
    if (th.vm.profiler) |p| p.check(th);
    if (th.vm.debugger) |dbg| dbg.check(th, fi, pc);
    if (th.vm.opstats) |s| s.record(th, fi, pc, ins);
    if (th.vm.tracer) |t| t.instruction(th, fi, base, pc, ins);
}

/// A fused form's B or C operand when it is not the stack: a register, a
/// constant or an upvalue.
inline fn operandValue(th: *Thread, fi: usize, stack: [*]Value, base: usize, consts: []const Value, x: u32) Value {
    if (x < d.first_constant) return stack[base + x];
    if (x < d.first_upvalue) return consts[x - d.first_constant];
    return th.frames.items[fi].cl.upvals[x - d.first_upvalue].get();
}

/// Stores a fused form's result: pushed, or into register a.
inline fn storeDest(stack: [*]Value, base: usize, top: *usize, a: u32, v: Value) void {
    if (a == d.push_dest) {
        stack[top.*] = v;
        top.* += 1;
    } else {
        stack[base + a] = v;
    }
}

/// get_table's inline cases: a table (then __index tables), a buffer
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

/// set_table's inline cases; false when the generic path (setTable) must
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

inline fn absIndex(top: usize, base: usize, idx: i32) usize {
    if (idx < 0) return @intCast(@as(i64, @intCast(top)) + idx);
    return base + @as(usize, @intCast(idx));
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
