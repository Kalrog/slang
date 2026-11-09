//! The interpreter loop of the register ISA (ops.zig). interp.run picks it
//! for a frame whose prototype is in that ISA, and this loop hands back to
//! run when a call or a return reaches a frame of the other ISA.
//!
//! What it shares with the stack loop (interp.zig): the arithmetic and
//! comparisons (numArith, compareSlow, arithMeta), the table fast paths and
//! the inline caches, the for..in table walk, the call machinery (precall,
//! Frame.dest, handleError) and the trace hook.
//!
//! The frame's registers are base .. base + max_stack, and th.top is their
//! end whenever something can collect, call out or raise (spill). A call
//! lowers it to the end of its arguments; what lies above is dead (see
//! ops.zig) and the collector clears it.

const std = @import("std");
const root = @import("../vm.zig");
const Value = root.Value;
const Table = root.Table;
const String = root.String;
const Thread = root.Thread;
const Error = root.Error;
const gc = @import("gc.zig");
const corelib = @import("../stdlib/core.zig");
const interp = @import("interp.zig");
const thread_mod = @import("thread.zig");
const d = @import("disasm.zig");
const ops = @import("ops.zig");
const Op = ops.Op;
const Ic = @import("table.zig").Ic;

pub fn run(th: *Thread, stop_depth: usize, comptime trace: bool) Error!void {
    const vm = th.vm;
    outer: while (true) {
        const n = th.frames.items.len;
        if (n <= stop_depth) return;
        const fi = n - 1;
        const frame = th.frames.items[fi];
        const cl = frame.cl;
        const proto = cl.proto orelse return vm.raise("internal error: native frame in interpreter loop", .{});
        if (proto.isa != .register) return;
        const code = proto.code;
        const consts = proto.consts;
        const base: usize = frame.base;
        // the end of the frame's registers
        const ftop: usize = base + proto.max_stack;
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
                stack[base + ops.argA(ins)] = .{ .int = ops.argSBx(ins) };
                continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
            },
            .load_bool => {
                stack[base + ops.argA(ins)] = .{ .bool = ops.argB(ins) != 0 };
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
                    .add, .sub, .mul, .div, .mod => if (interp.numArith(core, b, c)) |r| {
                        stack[base + ops.argA(ins)] = r;
                        continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                    },
                    .band, .bor, .bxor, .shl, .shr => if (b == .int and c == .int) {
                        if (interp.bitop(core, b.int, c.int)) |r| {
                            stack[base + ops.argA(ins)] = r;
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
                        const f = interp.metamethod(a, .null, "__unm");
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
                    const r = interp.bnotSlow(th, a) catch |e| {
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
                const core: d.Op = comptime switch (op) {
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
                } else if (if (core == .eq) interp.eqInline(l, r) else null) |e| {
                    res = e;
                } else {
                    spill(th, fi, pc, ftop);
                    res = interp.compareSlow(th, core, l, r) catch |e| {
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
                if (interp.getFastG(vm, obj, key, &getter)) |v| {
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
                if (interp.icGet(vm, ic, obj, &getter)) |v| {
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
                if (op == .set_field) quicken: {
                    const key = quickenable(proto, code, pc, consts[ops.argB(ins)], op) orelse break :quicken;
                    ins = quicken(vm, proto, code, pc, ins, key, op);
                    continue :sw .set_field_q;
                }
                const obj = if (op == .set_up_field) cl.upvals[ops.argA(ins)].get() else stack[base + ops.argA(ins)];
                const key = if (op == .set_index) stack[base + ops.argB(ins)] else consts[ops.argB(ins)];
                const val = rk(stack, base, consts, ins);
                if (interp.setFast(vm, obj, key, val)) continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                if (interp.findSetter(vm, obj, key)) |f| {
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
            .set_field_q => {
                const ic = &proto.ics.items[ops.cacheOf(ins)];
                if (interp.icStore(vm, ic, stack[base + ops.argA(ins)], rk(stack, base, consts, ins))) {
                    continue :sw fetch(trace, th, code, fi, base, &pc, ftop, &ins);
                }
                ins = ic.orig;
                continue :sw .set_field;
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
                if (interp.getFast(vm, obj, key)) |v| {
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
                if (interp.icGet(vm, ic, obj, &getter)) |f| {
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
                if (is_slang) continue :outer;
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
                continue :outer;
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
                    stack[ra] = .{ .int = k };
                    const c = if (flags & ops.for_flags.leq != 0) k <= limit.int else k < limit.int;
                    cont = c != (flags & ops.for_flags.negate != 0);
                } else {
                    const r = (if (is_sub) interp.numArith(.sub, i, step) else interp.numArith(.add, i, step)) orelse slow: {
                        spill(th, fi, pc, ftop);
                        const r = th.arithMeta(if (is_sub) .sub else .add, i, step) catch |e| {
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        stack = th.stack.ptr;
                        break :slow r;
                    };
                    stack[ra] = r;
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
                    if (interp.iterKind(f.function)) |kind| {
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
inline fn fetch(comptime trace: bool, th: *Thread, code: []const u32, fi: usize, base: usize, pc: *usize, ftop: usize, ins: *u32) Op {
    ins.* = code[pc.*];
    if (trace) {
        th.top = ftop;
        interp.traceInstruction(th, fi, base, pc.*, ins.*);
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

/// The stack ISA's operation an arithmetic opcode performs (numArith,
/// arithMeta and bitop are written for those).
fn coreOf(comptime op: Op) d.Op {
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

// ---- quickening (see interp.zig's inline caches)

/// The key of a get_field, get_up_field, self or set_field that can be
/// quickened: a constant string (for a store not a metamethod name), the
/// instruction not quickened already (after a miss it runs as itself),
/// room for another cache that the instruction can address.
inline fn quickenable(proto: *root.Proto, code: []u32, pc: usize, k: Value, comptime op: Op) ?*String {
    if (k != .string) return null;
    if (ops.opOf(code[pc - 1]) != op) return null;
    const room: usize = if (op == .set_field) ops.max_store_caches else ops.max_load_caches;
    if (proto.ics.items.len >= room) return null;
    if (op == .set_field) {
        const b = k.string.bytes();
        if (b.len >= 2 and b[0] == '_' and b[1] == '_') return null;
    }
    return k.string;
}

/// Gives the instruction a cache and rewrites it at pc - 1 into its
/// quickened form, which it returns.
fn quicken(vm: *root.VM, proto: *root.Proto, code: []u32, pc: usize, ins: u32, key: *String, comptime op: Op) u32 {
    const idx: u32 = @intCast(proto.ics.items.len);
    proto.ics.append(vm.gpa, .{ .key = key, .orig = ins, .keybit = Table.keyBit(key) }) catch root.oom();
    const quick: u32 = switch (op) {
        .get_field => ops.abc(.get_field_q, ops.argA(ins), ops.argB(ins), idx & 0xFF, idx >= 256),
        .get_up_field => ops.abc(.get_up_field_q, ops.argA(ins), ops.argB(ins), idx & 0xFF, idx >= 256),
        .self => ops.abc(.self_q, ops.argA(ins), ops.argB(ins), idx & 0xFF, idx >= 256),
        .set_field => ops.abc(.set_field_q, ops.argA(ins), idx, ops.argC(ins), ops.argK(ins)),
        else => unreachable,
    };
    code[pc - 1] = quick;
    return quick;
}
