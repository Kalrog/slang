const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const Value = root.Value;
const Table = root.Table;
const String = root.String;
const Thread = root.Thread;
const Error = root.Error;
const gc = @import("gc.zig");
const d = @import("disasm.zig");
const Op = d.Op;

/// Executes frames until the frame depth drops back to stop_depth.
///
/// The stack top and the stack base pointer live in locals while a frame
/// runs: `th.top` is written back, and both are reloaded (a call may grow
/// the stack), around everything that calls out: natives, metamethods, the
/// collector, error handling and the trace.
pub fn run(th: *Thread, stop_depth: usize) Error!void {
    // the trace check costs about 3% on call-heavy code when it sits in
    // every opcode, so the loop exists twice: with and without it
    if (th.vm.trace) return runImpl(th, stop_depth, true);
    return runImpl(th, stop_depth, false);
}

fn runImpl(th: *Thread, stop_depth: usize, comptime trace: bool) Error!void {
    th.run_depth += 1;
    defer th.run_depth -= 1;
    const vm = th.vm;
    const gpa = vm.gpa;
    outer: while (true) {
        const n = th.frames.items.len;
        if (n <= stop_depth) return;
        const fi = n - 1;
        const frame = th.frames.items[fi];
        const proto = frame.cl.proto orelse return vm.raise("internal error: native frame in interpreter loop", .{});
        const code = proto.code;
        const consts = proto.consts;
        const base: usize = frame.base;
        var pc: usize = frame.pc;
        var top: usize = th.top;
        var stack: [*]Value = th.stack.ptr;
        var ins = code[pc];
        if (trace) {
            th.top = top;
            traceInstruction(th, fi, base, pc, ins);
        }
        pc += 1;
        th.frames.items[fi].pc = @intCast(pc);
        // labelled switch: every opcode fetches the next instruction and
        // jumps straight to its case
        sw: switch (d.opOf(ins)) {
            .load_constant => {
                stack[top] = consts[d.argBx(ins)];
                top += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .load_bool => {
                stack[top] = .{ .bool = d.argB(ins) != 0 };
                top += 1;
                if (d.argC(ins) != 0) pc += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .load_closure => {
                th.top = top;
                gc.safePoint(vm, th);
                const cl = th.makeClosure(th.frames.items[fi], proto.children[d.argAx(ins)]);
                stack[top] = .{ .function = cl };
                top += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .add => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                if (a == .int and b == .int) {
                    top -= 1;
                    stack[top - 1] = .{ .int = a.int +% b.int };
                    ins = code[pc];
                    if (trace) {
                        th.top = top;
                        traceInstruction(th, fi, base, pc, ins);
                    }
                    pc += 1;
                    th.frames.items[fi].pc = @intCast(pc);
                    continue :sw d.opOf(ins);
                }
                // operands stay on the stack during the (possibly
                // allocating) operation so the collector can see them
                th.top = top;
                const r = th.arithMeta(.add, a, b) catch |e| {
                    th.top -= 2;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top - 1;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .sub => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                if (a == .int and b == .int) {
                    top -= 1;
                    stack[top - 1] = .{ .int = a.int -% b.int };
                    ins = code[pc];
                    if (trace) {
                        th.top = top;
                        traceInstruction(th, fi, base, pc, ins);
                    }
                    pc += 1;
                    th.frames.items[fi].pc = @intCast(pc);
                    continue :sw d.opOf(ins);
                }
                th.top = top;
                const r = th.arithMeta(.sub, a, b) catch |e| {
                    th.top -= 2;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top - 1;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .mul, .div, .mod, .pow, .band, .bor, .bxor, .shl, .shr => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                th.top = top;
                const r = th.arithMeta(d.opOf(ins), a, b) catch |e| {
                    th.top -= 2;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top - 1;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .neg => {
                const a = stack[top - 1];
                switch (a) {
                    .int => |i| stack[top - 1] = .{ .int = 0 -% i },
                    .float => |f| stack[top - 1] = .{ .float = -f },
                    else => {
                        th.top = top;
                        const f = metamethod(a, .null, "__unm");
                        if (f == .function) {
                            const r = th.call(f, &.{a}) catch |e| {
                                try th.handleError(e, stop_depth);
                                continue :outer;
                            };
                            top = th.top;
                            stack = th.stack.ptr;
                            stack[top - 1] = r;
                            ins = code[pc];
                            if (trace) {
                                th.top = top;
                                traceInstruction(th, fi, base, pc, ins);
                            }
                            pc += 1;
                            th.frames.items[fi].pc = @intCast(pc);
                            continue :sw d.opOf(ins);
                        }
                        vm.setError("attempt to negate a {s} value", .{a.typeName()});
                        try th.handleError(error.Slang, stop_depth);
                        continue :outer;
                    },
                }
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .bnot => {
                const a = stack[top - 1];
                if (a == .int) {
                    stack[top - 1] = .{ .int = ~a.int };
                } else {
                    th.top = top;
                    const r = bnotSlow(th, a) catch |e| {
                        try th.handleError(e, stop_depth);
                        continue :outer;
                    };
                    top = th.top;
                    stack = th.stack.ptr;
                    stack[top - 1] = r;
                }
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .not => {
                // Read into a local first: writing `.{ .bool = ... }` straight
                // into the slot sets the tag before the operand is evaluated
                // (Zig result-location semantics).
                const v = stack[top - 1];
                stack[top - 1] = .{ .bool = !v.truthy() };
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .eq => {
                const b = stack[top - 1];
                const a = stack[top - 2];
                top -= 1;
                if (a.kind() == b.kind() and (a == .table or a == .userdata)) {
                    const f = metamethod(a, b, "__eq");
                    if (f == .function) {
                        th.top = top;
                        const r = th.call(f, &.{ a, b }) catch |e| {
                            th.top -= 1;
                            try th.handleError(e, stop_depth);
                            continue :outer;
                        };
                        top = th.top;
                        stack = th.stack.ptr;
                        stack[top - 1] = .{ .bool = r.truthy() };
                        ins = code[pc];
                        if (trace) {
                            th.top = top;
                            traceInstruction(th, fi, base, pc, ins);
                        }
                        pc += 1;
                        th.frames.items[fi].pc = @intCast(pc);
                        continue :sw d.opOf(ins);
                    }
                }
                stack[top - 1] = .{ .bool = a.equals(b) };
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
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
                    th.top = top;
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
                        ins = code[pc];
                        if (trace) {
                            th.top = top;
                            traceInstruction(th, fi, base, pc, ins);
                        }
                        pc += 1;
                        th.frames.items[fi].pc = @intCast(pc);
                        continue :sw d.opOf(ins);
                    }
                    th.top -= 1;
                    vm.setError("attempt to compare {s} {s} {s}", .{ a.typeName(), if (is_lt) "<" else "<=", b.typeName() });
                    try th.handleError(error.Slang, stop_depth);
                    continue :outer;
                }
                stack[top - 1] = .{ .bool = r };
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .move => {
                const v = stack[top - 1];
                top -= 1;
                stack[absIndex(top, base, d.argSBx(ins))] = v;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .push => {
                stack[top] = stack[absIndex(top, base, d.argSBx(ins))];
                top += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .pop => {
                const keep: usize = d.argA(ins);
                const drop: usize = d.argBx(ins);
                if (keep > 0) {
                    std.mem.copyForwards(Value, stack[top - drop - keep .. top - drop], stack[top - keep .. top]);
                }
                top -= drop;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .@"return" => {
                var res = stack[top - 1];
                const fn_idx = base - 1;
                const prot = th.frames.items[fi].protected;
                th.top = top;
                th.popFrame();
                th.top = fn_idx;
                if (prot) res = okResult(th, res);
                th.push(res);
                if (th.frames.items.len == stop_depth) return;
                continue :outer;
            },
            .new_table => {
                th.top = top;
                gc.safePoint(vm, th);
                stack[top] = .{ .table = vm.newTable(d.argB(ins), d.argC(ins)) };
                top += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .set_table => {
                const val = stack[top - 1];
                const key = stack[top - 2];
                const obj = stack[top - 3];
                top -= 3;
                if (obj == .table and key == .string) {
                    const t = obj.table;
                    if (t.meta == null and !key.string.eqlBytes("meta")) {
                        t.setStr(gpa, key.string, val);
                        ins = code[pc];
                        if (trace) {
                            th.top = top;
                            traceInstruction(th, fi, base, pc, ins);
                        }
                        pc += 1;
                        th.frames.items[fi].pc = @intCast(pc);
                        continue :sw d.opOf(ins);
                    }
                }
                th.top = top;
                th.setTable(obj, key, val) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .get_table => {
                const key = stack[top - 1];
                const obj = stack[top - 2];
                top -= 1;
                if (obj == .table) {
                    const t = obj.table;
                    const v = switch (key) {
                        .string => |s| t.getStr(s),
                        .int => |i| t.getInt(i),
                        else => t.get(key),
                    };
                    if (v != .null or t.meta == null) {
                        stack[top - 1] = v;
                        ins = code[pc];
                        if (trace) {
                            th.top = top;
                            traceInstruction(th, fi, base, pc, ins);
                        }
                        pc += 1;
                        th.frames.items[fi].pc = @intCast(pc);
                        continue :sw d.opOf(ins);
                    }
                }
                top -= 1;
                th.top = top;
                const v = th.getTable(obj, key) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                stack[top] = v;
                top += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .set_upvalue => {
                const v = stack[top - 1];
                top -= 1;
                th.frames.items[fi].cl.upvals[d.argAx(ins)].set(v);
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .get_upvalue => {
                stack[top] = th.frames.items[fi].cl.upvals[d.argAx(ins)].get();
                top += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .close_upvalues => {
                th.closeUpvalues(base + d.argAx(ins));
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .@"test" => {
                const v = stack[top - 1];
                top -= 1;
                if (v.truthy() != (d.argC(ins) != 0)) pc += 1;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .jump => {
                const off = d.argSBx(ins);
                if (off < 0) {
                    th.top = top;
                    gc.safePoint(vm, th);
                }
                pc = @intCast(@as(i64, @intCast(pc)) + off);
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .call_spread => {
                th.top = top;
                gc.safePoint(vm, th);
                const fixed: usize = d.argBx(ins);
                const list = stack[top - 1];
                if (list != .table) {
                    vm.setError("attempt to spread a {s} value", .{list.typeName()});
                    try th.handleError(error.Slang, stop_depth);
                    continue :outer;
                }
                const items = list.table.arr.items;
                top -= 1;
                th.top = top;
                th.ensure(top + items.len + 8) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                stack = th.stack.ptr;
                for (items) |v| {
                    stack[top] = v;
                    top += 1;
                }
                th.top = top;
                const nargs = fixed + items.len;
                const fn_idx = top - nargs - 1;
                const is_slang = th.precall(fn_idx, nargs, false) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                if (is_slang) continue :outer;
                top = th.top;
                stack = th.stack.ptr;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .call => {
                th.top = top;
                gc.safePoint(vm, th);
                const nargs: usize = d.argBx(ins);
                const fn_idx = top - nargs - 1;
                const is_slang = th.precall(fn_idx, nargs, false) catch |e| {
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                if (is_slang) continue :outer;
                top = th.top;
                stack = th.stack.ptr;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .type => {
                const v = stack[top - 1];
                th.top = top;
                const r = th.typeOf(v) catch |e| {
                    th.top -= 1;
                    try th.handleError(e, stop_depth);
                    continue :outer;
                };
                top = th.top;
                stack = th.stack.ptr;
                stack[top - 1] = r;
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .try_begin => {
                const off = d.argSBx(ins);
                th.pushHandler(.{
                    .frame = @intCast(fi),
                    .pc = @intCast(@as(i64, @intCast(pc)) + off),
                    .top = @intCast(top),
                    .close_from = @intCast(base + d.argA(ins)),
                });
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .try_end => {
                _ = th.handlers.pop();
                ins = code[pc];
                if (trace) {
                    th.top = top;
                    traceInstruction(th, fi, base, pc, ins);
                }
                pc += 1;
                th.frames.items[fi].pc = @intCast(pc);
                continue :sw d.opOf(ins);
            },
            .throw => {
                const v = stack[top - 1];
                th.top = top - 1;
                vm.setErrorFromValue(v);
                try th.handleError(error.Slang, stop_depth);
                continue :outer;
            },
            _ => {
                th.top = top;
                return vm.raise("unknown opcode {d}", .{ins & 0x3F});
            },
        }
    }
}

fn traceInstruction(th: *Thread, fi: usize, base: usize, pc: usize, ins: u32) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("[{d}] base={d} top={d} pc={d}: ", .{ fi, base, th.top, pc }) catch {};
    d.writeInstruction(&w, ins) catch {};
    w.writeAll("  stack:") catch {};
    var i = base;
    while (i < th.top and i < base + 12) : (i += 1) {
        w.writeByte(' ') catch {};
        var vb: [40]u8 = undefined;
        var vw: std.Io.Writer = .fixed(&vb);
        root.format.writeValue(&vw, th.stack[i]) catch {};
        w.writeAll(vw.buffered()) catch {};
    }
    w.writeByte('\n') catch {};
    var eb: [64]u8 = undefined;
    var ew = std.Io.File.stderr().writerStreaming(th.vm.io, &eb);
    ew.interface.writeAll(w.buffered()) catch {};
    ew.interface.flush() catch {};
}

inline fn absIndex(top: usize, base: usize, idx: i32) usize {
    if (idx < 0) return @intCast(@as(i64, @intCast(top)) + idx);
    return base + @as(usize, @intCast(idx));
}

fn okResult(th: *Thread, v: Value) Value {
    const t = th.vm.newTable(2, 0);
    t.append(th.vm.gpa, th.vm.str("ok"));
    t.pushSlot(th.vm.gpa, v);
    return .{ .table = t };
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
fn bitop(op: Op, x: i64, y: i64) ?Value {
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
fn bnotSlow(th: *Thread, a: Value) Error!Value {
    if (exactInt(a)) |x| return .{ .int = ~x };
    const f = metamethod(a, .null, "__bnot");
    if (f == .function) return th.call(f, &.{a});
    if (a == .float) return th.vm.raise("number has no integer representation in bitwise operation (~)", .{});
    return th.vm.raise("attempt to perform bitwise operation (~) on a {s} value", .{a.typeName()});
}

/// A binary arithmetic operation on built-in types. Returns null when the
/// operands do not support it.
fn arith(th: *Thread, op: Op, a: Value, b: Value) ?Value {
    if (isBitOp(op)) {
        const x = exactInt(a) orelse return null;
        const y = exactInt(b) orelse return null;
        return bitop(op, x, y);
    }
    if (a == .int and b == .int) {
        const x = a.int;
        const y = b.int;
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
    if (a.isNumber() and b.isNumber()) {
        const x = a.asNumber();
        const y = b.asNumber();
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
        if (op == .mod and a == .int and b == .int) return th.vm.raise("integer modulo by zero", .{});
        if (isBitOp(op) and a.isNumber() and b.isNumber()) {
            if (exactInt(a) != null and exactInt(b) != null) return th.vm.raise("negative shift amount", .{});
            return th.vm.raise("number has no integer representation in bitwise operation ({s})", .{op.symbol()});
        }
        const f = metamethod(a, b, arithMetaName(op));
        if (f == .function) return th.call(f, &.{ a, b });
        if (isBitOp(op)) {
            if (a.kind() == b.kind()) return th.vm.raise("attempt to perform bitwise operation ({s}) on {s} values", .{ op.symbol(), a.typeName() });
            return th.vm.raise("attempt to perform bitwise operation ({s}) on {s} and {s}", .{ op.symbol(), a.typeName(), b.typeName() });
        }
        return th.vm.raise("attempt to perform arithmetic ({s}) on {s} and {s}", .{ op.symbol(), a.typeName(), b.typeName() });
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
                    if (raw != .null) return raw;
                    meta = t.meta;
                },
                .userdata => |u| meta = u.meta,
                .null => {
                    var buf: [256]u8 = undefined;
                    return th.vm.raise("attempt to index a null value (key {s})", .{keyDesc(&buf, key)});
                },
                else => return .null,
            }
            const m = meta orelse return .null;
            const idx = m.getName("__index");
            switch (idx) {
                .function => return th.call(idx, &.{ obj, key }),
                .table => obj = idx,
                else => return .null,
            }
        }
        return th.vm.raise("__index chain too long", .{});
    }

    /// Assignment with __newindex metamethods.
    pub fn setTable(th: *Thread, obj_: Value, key: Value, val: Value) Error!void {
        var obj = obj_;
        var depth: usize = 0;
        while (depth < 100) : (depth += 1) {
            switch (obj) {
                .table => |t| {
                    if (key == .null) return th.vm.raise("table index is null", .{});
                    const m = t.meta orelse return th.rawSet(t, key, val);
                    if (t.get(key) != .null) return th.rawSet(t, key, val);
                    const ni = m.getName("__newindex");
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
                    if (u.meta) |m| {
                        const ni = m.getName("__newindex");
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
                    return th.vm.raise("cannot set value on userdata", .{});
                },
                .null => {
                    var buf: [256]u8 = undefined;
                    return th.vm.raise("attempt to index a null value (key {s})", .{keyDesc(&buf, key)});
                },
                else => {
                    var buf: [256]u8 = undefined;
                    return th.vm.raise("attempt to index a {s} value (key {s})", .{ obj.typeName(), keyDesc(&buf, key) });
                },
            }
        }
        return th.vm.raise("__newindex chain too long", .{});
    }

    pub fn rawSet(th: *Thread, t: *Table, key: Value, val: Value) Error!void {
        if (key == .string and key.string.eqlBytes("meta")) {
            switch (val) {
                .table => |m| t.meta = m,
                .null => t.meta = null,
                else => return th.vm.raise("meta must be a table, got {s}", .{val.typeName()}),
            }
            return;
        }
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
            .table => |t| .{ .int = @intCast(t.len()) },
            .string => |s| .{ .int = @intCast(s.len) },
            else => th.vm.raise("len requires a table or string", .{}),
        };
    }
};
