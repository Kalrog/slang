const std = @import("std");
const root = @import("../vm.zig");
const Proto = root.Proto;
const Writer = std.Io.Writer;
const ops = @import("ops.zig");

/// Opcodes. The encoding is the one of the Dart implementation:
///
///   31       23       14       6     0
///   |b=9bits |c=9bits |a=8bits |op=6|
///   |    bx=18bits    |a=8bits |op=6|   sbx = bx - 0x1FFFF
///   |    ax=26bits             |op=6|
pub const Op = enum(u6) {
    load_constant = 0, // push K[bx]
    load_bool, // push bool(b); if c: pc++
    load_closure, // push closure(children[ax])
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    not,
    eq,
    lt,
    leq,
    move, // stack[sbx] = pop()
    push, // push stack[sbx]
    pop, // keep top a, drop bx beneath
    @"return", // return top
    new_table, // push {} (b array hint, c hash hint)
    set_table, // t[k] = v (pops 3)
    get_table, // push t[k] (pops 2)
    set_upvalue, // upvals[ax] = pop()
    get_upvalue, // push upvals[ax]
    close_upvalues, // close upvalues >= ax
    @"test", // if truthy(top) != c: pc++ ; pop
    jump, // pc += sbx
    call, // call with bx args
    type, // replace top with its type
    pow, // a ^ b
    band, // a & b
    bor, // a | b
    bxor, // a ~ b
    shl, // a << b
    shr, // a >> b (arithmetic)
    bnot, // ~a
    call_spread, // call with bx fixed args followed by a list of the rest
    try_begin, // push a handler: on an error, pc += sbx, close upvalues >= a
    try_end, // pop the innermost handler
    throw, // raise pop()
    get_meta, // push(meta of pop()): x.@meta, null for a value without one
    set_meta, // m = pop(); t = pop(); t's metatable = m (a table or null)
    // a for..in over f(x): when f is the built-in keys, values or entries
    // and x a table, x stays as the iterator and r[a] is the
    // position; anything else: call f(x) (as call with one argument)
    forin_prep,
    // a for..in step; the next two words are jumps: the loop's end and its
    // pattern. A table iterator (forin_prep) pushes its next element and
    // takes the second (or pushes null and takes the first at the end); a
    // function iterator skips both, to the call that follows
    forin_next,

    // The quickened forms: get_x, self_x and set_x with a constant string
    // key become these when they first run (interp.quicken); the key
    // operand (C, for set_k B) is the index of an inline cache in
    // Proto.ics instead. Never in bytecode files (slb writes Ic.orig).
    get_k = 47,
    self_k = 48,
    set_k = 49,

    // The fused forms (the `fused` profile), numbered from 63 down so the
    // core can grow upward. B and C are operands (see `operand`); A is a
    // destination register, 255 for a push.
    for_loop = 50, // r[a] += B (or -=), compare with C, jump; the next word is the jump to the body, its A the flags (`for_flags`)
    self_x, // obj = B (the top when 511, kept): push obj[C], obj
    move_x, // r[a] = B
    set_x, // obj[B] = C; obj is r[a], 254: the top (kept), 255: popped; B 511: popped (above obj)
    get_x, // dest = B[C]
    jtest, // if truthy(B) != a: pc++ (the next word is a jump)
    jeq, // if (B == C) != a: pc++ (the next word is a jump)
    jleq, // if (B <= C) != a: pc++
    jlt, // if (B < C) != a: pc++
    mod_x, // dest = B % C
    div_x, // dest = B / C
    mul_x, // dest = B * C
    sub_x, // dest = B - C
    add_x, // dest = B + C
    _,

    pub fn name(op: Op) []const u8 {
        return switch (op) {
            .load_constant => "loadConstant",
            .load_bool => "loadBool",
            .load_closure => "loadClosure",
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "mod",
            .neg => "neg",
            .not => "not",
            .eq => "eq",
            .lt => "lt",
            .leq => "leq",
            .move => "move",
            .push => "push",
            .pop => "pop",
            .@"return" => "returnOp",
            .new_table => "newTable",
            .set_table => "setTable",
            .get_table => "getTable",
            .set_upvalue => "setUpvalue",
            .get_upvalue => "getUpvalue",
            .close_upvalues => "closeUpvalues",
            .@"test" => "test",
            .jump => "jump",
            .call => "call",
            .type => "type",
            .pow => "pow",
            .band => "band",
            .bor => "bor",
            .bxor => "bxor",
            .shl => "shl",
            .shr => "shr",
            .bnot => "bnot",
            .call_spread => "callSpread",
            .try_begin => "tryBegin",
            .try_end => "tryEnd",
            .throw => "throw",
            .get_meta => "getMeta",
            .set_meta => "setMeta",
            .forin_prep => "forinPrep",
            .forin_next => "forinNext",
            .add_x => "addX",
            .sub_x => "subX",
            .mul_x => "mulX",
            .div_x => "divX",
            .mod_x => "modX",
            .jlt => "jlt",
            .jleq => "jleq",
            .jeq => "jeq",
            .jtest => "jtest",
            .get_x => "getX",
            .set_x => "setX",
            .move_x => "moveX",
            .self_x => "selfX",
            .for_loop => "forLoop",
            .get_k => "getK",
            .self_k => "selfK",
            .set_k => "setK",
            _ => "op?",
        };
    }

    pub fn symbol(op: Op) []const u8 {
        return switch (op) {
            .add, .add_x => "+",
            .sub, .sub_x => "-",
            .mul, .mul_x => "*",
            .div, .div_x => "/",
            .mod, .mod_x => "%",
            .pow => "^",
            .band => "&",
            .bor => "|",
            .bxor, .bnot => "~",
            .shl => "<<",
            .shr => ">>",
            else => op.name(),
        };
    }
};

/// The opcodes below this one are the core ISA.
pub const first_fused: u6 = @intFromEnum(Op.for_loop);

/// Whether an opcode is one of the quickened forms (see Op.get_k).
pub inline fn isQuickened(op: Op) bool {
    return op == .get_k or op == .self_k or op == .set_k;
}

pub inline fn isFused(op: Op) bool {
    return @intFromEnum(op) >= first_fused;
}

/// The core arithmetic or comparison a fused form performs.
pub fn coreOf(comptime op: Op) Op {
    return switch (op) {
        .add_x => .add,
        .sub_x => .sub,
        .mul_x => .mul,
        .div_x => .div,
        .mod_x => .mod,
        .jlt => .lt,
        .jleq => .leq,
        .jeq => .eq,
        else => unreachable,
    };
}

/// A fused form's B or C operand: a register, a constant, an upvalue or
/// the value on top of the stack.
pub const Operand = union(enum) { register: u32, constant: u32, upvalue: u32, stack };

pub const first_constant = 128;
pub const first_upvalue = 384;
pub const stack_operand = 511;
/// A destination of 255 pushes the result; set_x's object of 254 is the
/// top of the stack, kept there.
pub const push_dest = 255;
pub const peek_dest = 254;

pub fn operand(x: u32) Operand {
    if (x < first_constant) return .{ .register = x };
    if (x < first_upvalue) return .{ .constant = x - first_constant };
    if (x < stack_operand) return .{ .upvalue = x - first_upvalue };
    return .stack;
}

/// The flags of a for_loop, in the A of the jump word after it.
pub const for_flags = struct {
    pub const leq = 1; // the condition is <= (else <)
    pub const negate = 2; // the loop goes on while the condition is false
    pub const sub = 4; // the update subtracts the step
};

const Mode = enum { abc, abx, asbx, ax, none, fused };

fn mode(op: Op) Mode {
    return switch (op) {
        .load_constant, .pop, .call, .call_spread => .abx,
        .load_bool, .new_table, .@"test", .forin_prep, .forin_next => .abc,
        .load_closure, .set_upvalue, .get_upvalue, .close_upvalues => .ax,
        .move, .push, .jump, .try_begin => .asbx,
        else => if (isFused(op)) .fused else .none,
    };
}

pub inline fn opOf(ins: u32) Op {
    return @fromBackingInt(@intCast(@as(u6, @truncate(ins))));
}
pub inline fn argA(ins: u32) u32 {
    return (ins >> 6) & 0xFF;
}
pub inline fn argB(ins: u32) u32 {
    return (ins >> 23) & 0x1FF;
}
pub inline fn argC(ins: u32) u32 {
    return (ins >> 14) & 0x1FF;
}
pub inline fn argBx(ins: u32) u32 {
    return ins >> 14;
}
pub inline fn argSBx(ins: u32) i32 {
    return @as(i32, @intCast(ins >> 14)) - 0x1FFFF;
}
pub inline fn argAx(ins: u32) u32 {
    return ins >> 6;
}

/// Renders one instruction.
pub fn writeInstruction(w: *Writer, ins: u32) Writer.Error!void {
    const op = opOf(ins);
    const name = op.name();
    switch (mode(op)) {
        .abc => try w.print("{s} A={d} B={d} C={d}", .{ name, argA(ins), argB(ins), argC(ins) }),
        .abx => try w.print("{s} A={d} Bx={d}", .{ name, argA(ins), argBx(ins) }),
        .asbx => try w.print("{s} A={d} sBx={d}", .{ name, argA(ins), argSBx(ins) }),
        .ax => try w.print("{s} Ax={d}", .{ name, argAx(ins) }),
        .none => try w.writeAll(name),
        .fused => {
            try w.writeAll(name);
            switch (op) {
                .jlt, .jleq, .jeq, .jtest => try w.print(" A={d}", .{argA(ins)}),
                .set_x => switch (argA(ins)) {
                    push_dest => try w.writeAll(" top"),
                    peek_dest => try w.writeAll(" top(kept)"),
                    else => |r| try w.print(" r{d}", .{r}),
                },
                .self_x => {},
                else => if (argA(ins) == push_dest) try w.writeAll(" push") else try w.print(" r{d}", .{argA(ins)}),
            }
            try writeOperand(w, argB(ins));
            if (op != .move_x and op != .jtest) try writeOperand(w, argC(ins));
        },
    }
}

fn writeOperand(w: *Writer, x: u32) Writer.Error!void {
    switch (operand(x)) {
        .register => |r| try w.print(" r{d}", .{r}),
        .constant => |k| try w.print(" k{d}", .{k}),
        .upvalue => |u| try w.print(" u{d}", .{u}),
        .stack => try w.writeAll(" top"),
    }
}

/// Renders a prototype and its children.
pub fn disassemble(w: *Writer, p: *const Proto) Writer.Error!void {
    try disasmProto(w, p, "");
}

/// What an instruction refers to, for the reader: the constant loaded, the
/// upvalue's name, the field a getTable reads, a jump's target, a test's
/// sense, a closure's shape.
fn annotate(w: *Writer, p: *const Proto, pc: usize, ins: u32) Writer.Error!void {
    switch (opOf(ins)) {
        .load_constant => {
            const idx = argBx(ins);
            if (idx < p.consts.len) try annotateConstant(w, p.consts[idx]);
        },
        .load_bool => {
            try w.writeAll(if (argB(ins) != 0) "true" else "false");
            if (argC(ins) != 0) try w.writeAll(", skip next");
        },
        .load_closure => {
            const idx = argAx(ins);
            if (idx < p.children.len) {
                const c = p.children[idx];
                try w.print("function #{d} (nargs={d}{s})", .{ idx, c.nargs, if (c.is_vararg) " vararg" else "" });
            }
        },
        .get_upvalue, .set_upvalue => {
            const idx = argAx(ins);
            if (idx < p.upvals.len) try w.writeAll(p.upvals[idx].name.bytes());
        },
        .get_table => {
            // t.name: the key was loaded just before
            if (pc > 0 and opOf(p.code[pc - 1]) == .load_constant) {
                const idx = argBx(p.code[pc - 1]);
                if (idx < p.consts.len and p.consts[idx] == .string) {
                    try w.print(".{s}", .{p.consts[idx].string.bytes()});
                }
            }
        },
        .jump => try w.print("-> {d}", .{@as(i64, @intCast(pc)) + 1 + argSBx(ins)}),
        .try_begin => try w.print("handler -> {d}, close from register {d}", .{ @as(i64, @intCast(pc)) + 1 + argSBx(ins), argA(ins) }),
        .@"test" => try w.writeAll(if (argC(ins) != 0) "skip next when false" else "skip next when true"),
        .push, .move => {
            const sbx = argSBx(ins);
            if (sbx < 0) try w.print("top{d}", .{sbx}) else try w.print("register {d}", .{sbx});
        },
        .pop => try w.print("keep {d}, drop {d}", .{ argA(ins), argBx(ins) }),
        .new_table => try w.print("array {d}, hash {d}", .{ argB(ins), argC(ins) }),
        .call => try w.print("{d} arg{s}", .{ argBx(ins), if (argBx(ins) == 1) "" else "s" }),
        .call_spread => try w.print("{d} fixed args and a list", .{argBx(ins)}),
        .close_upvalues => try w.print("from register {d}", .{argAx(ins)}),
        else => |op| if (isFused(op)) {
            var first = true;
            for ([_]u32{ argB(ins), argC(ins) }, 0..) |x, i| {
                if (i == 1 and (op == .move_x or op == .jtest)) break;
                switch (operand(x)) {
                    .constant => |k| if (k < p.consts.len) {
                        if (!first) try w.writeAll(", ");
                        first = false;
                        try annotateConstant(w, p.consts[k]);
                    },
                    .upvalue => |u| if (u < p.upvals.len) {
                        if (!first) try w.writeAll(", ");
                        first = false;
                        try w.writeAll(p.upvals[u].name.bytes());
                    },
                    else => {},
                }
            }
            switch (op) {
                .jlt, .jleq, .jeq, .jtest => try w.writeAll(if (first) "" else "; "),
                else => {},
            }
            switch (op) {
                .jlt, .jleq, .jeq, .jtest => try w.writeAll(if (argA(ins) != 0) "skip next when false" else "skip next when true"),
                .for_loop => if (pc + 1 < p.code.len) {
                    const j = p.code[pc + 1];
                    const f = argA(j);
                    if (!first) try w.writeAll("; ");
                    try w.print("{s} {s}{s}, body -> {d}", .{
                        if (f & for_flags.sub != 0) "-=" else "+=",
                        if (f & for_flags.negate != 0) "until " else "while ",
                        if (f & for_flags.leq != 0) "<=" else "<",
                        @as(i64, @intCast(pc)) + 2 + argSBx(j),
                    });
                },
                else => {},
            }
        },
    }
}

fn annotateConstant(w: *Writer, c: root.Value) Writer.Error!void {
    if (c == .string) {
        const b = c.string.bytes();
        if (b.len > 40) {
            try writeQuoted(w, b[0..40]);
            try w.print("... ({d} bytes)", .{b.len});
        } else {
            try writeQuoted(w, b);
        }
    } else {
        try root.format.writeValue(w, c);
    }
}

fn disasmProto(w: *Writer, p: *const Proto, indent: []const u8) Writer.Error!void {
    if (p.isa == .register) {
        try w.print("{s}function (nargs={d} vararg={} registers={d})\n", .{ indent, p.nargs, p.is_vararg, p.max_stack });
    } else {
        try w.print("{s}function (nargs={d} vararg={} maxstack={d} temps={d})\n", .{ indent, p.nargs, p.is_vararg, p.max_stack, p.temps });
    }
    try w.print("{s}Instructions:\n", .{indent});
    for (p.code, 0..) |quick, i| {
        // (as compiled: a quickened instruction as it was)
        const ins = p.original(quick);
        // the instruction, padded, then `; annotation`, then the location
        var ibuf: [64]u8 = undefined;
        var iw: Writer = .fixed(&ibuf);
        var abuf: [128]u8 = undefined;
        var aw: Writer = .fixed(&abuf);
        if (p.isa == .register) {
            ops.writeInstruction(&iw, ins) catch {};
            ops.annotate(&aw, p, i, ins) catch {};
        } else {
            writeInstruction(&iw, ins) catch {};
            annotate(&aw, p, i, ins) catch {};
        }
        var loc: ?*const @import("object.zig").LocInfo = null;
        for (p.locs) |*l| {
            if (l.first_pc == i) {
                loc = l;
                break;
            }
        }
        const ann = aw.buffered();
        if (loc) |l| {
            try w.print("{s}  {d:4}: {s:<30}", .{ indent, i, iw.buffered() });
            if (ann.len > 0) try w.print(" ; {s:<28}", .{ann}) else try w.print("{s:<31}", .{""});
            try w.print("  {s}:{d}:{d}", .{ l.origin.bytes(), l.line, l.column });
        } else if (ann.len > 0) {
            try w.print("{s}  {d:4}: {s:<30} ; {s}", .{ indent, i, iw.buffered(), ann });
        } else {
            try w.print("{s}  {d:4}: {s}", .{ indent, i, iw.buffered() });
        }
        try w.writeByte('\n');
    }
    if (p.locals.len > 0) {
        try w.print("{s}Locals:\n", .{indent});
        for (p.locals) |l| {
            try w.print("{s}  r{d} {s} pc {d}..{d}\n", .{ indent, l.reg, l.name.bytes(), l.start_pc, l.end_pc });
        }
    }
    if (p.consts.len > 0) {
        try w.print("{s}Constants:\n", .{indent});
        for (p.consts, 0..) |c, i| {
            if (c == .string) {
                try w.print("{s}  {d}: ", .{ indent, i });
                try writeQuoted(w, c.string.bytes());
                try w.writeByte('\n');
            } else {
                try w.print("{s}  {d}: ", .{ indent, i });
                try root.format.writeValue(w, c);
                try w.writeByte('\n');
            }
        }
    }
    if (p.upvals.len > 0) {
        try w.print("{s}Upvalues:\n", .{indent});
        for (p.upvals, 0..) |u, i| {
            try w.print("{s}  {d}: {s} index={d} local={}\n", .{ indent, i, u.name.bytes(), u.index, u.is_local });
        }
    }
    if (p.children.len > 0) {
        try w.print("{s}Children:\n", .{indent});
        var buf: [256]u8 = undefined;
        const sub = std.fmt.bufPrint(&buf, "{s}    ", .{indent}) catch indent;
        for (p.children, 0..) |c, i| {
            try w.print("{s}  {d}:\n", .{ indent, i });
            try disasmProto(w, c, sub);
        }
    }
}

/// Go %q style quoting (enough for the characters that occur in constants).
fn writeQuoted(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

/// The most values a function's code has on the stack above its registers
/// at once (its expression temporaries: a call's function and arguments,
/// operands): the code is walked along its jumps with each instruction's
/// effect on the top. A frame reserves these besides max_stack, because the
/// interpreter writes its pushes without checking the stack's length.
pub fn maxTemps(gpa: std.mem.Allocator, code: []const u32) u32 {
    if (code.len == 0) return 0;
    const depth = gpa.alloc(i32, code.len) catch return @intCast(code.len + 8);
    defer gpa.free(depth);
    @memset(depth, -1);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    var max: i32 = 0;
    const visit = struct {
        fn f(g: std.mem.Allocator, dp: []i32, wl: *std.ArrayList(u32), at: i64, dv: i32) void {
            if (at < 0 or at >= dp.len) return;
            const i: usize = @intCast(at);
            const v = @max(dv, 0);
            if (dp[i] >= v) return;
            dp[i] = v;
            wl.append(g, @intCast(i)) catch {};
        }
    }.f;
    visit(gpa, depth, &work, 0, 0);
    while (work.pop()) |idx| {
        const i: i64 = idx;
        const dv = depth[idx];
        const ins = code[idx];
        const op = opOf(ins);
        const b = argB(ins);
        const popped: i32 = @intFromBool(b == stack_operand);
        const pushes: i32 = @intFromBool(argA(ins) == push_dest);
        // the effect on the top, and where the code goes on
        var delta: i32 = 0;
        var next = true;
        switch (op) {
            .load_constant, .load_closure, .push, .new_table, .get_upvalue => delta = 1,
            .load_bool => {
                delta = 1;
                if (argC(ins) != 0) {
                    visit(gpa, depth, &work, i + 2, dv + 1);
                    next = false;
                }
            },
            .add, .sub, .mul, .div, .mod, .eq, .lt, .leq, .pow, .band, .bor, .bxor, .shl, .shr, .get_table, .move, .set_upvalue => delta = -1,
            .neg, .not, .bnot, .type, .get_meta, .close_upvalues, .try_end, .move_x => delta = 0,
            .pop => delta = -@as(i32, @intCast(argBx(ins))),
            .set_table => delta = -3,
            .set_meta => delta = -2,
            // (f and x become the iterator, as a call of f(x) does)
            .forin_prep => delta = -1,
            .forin_next => {
                // an element and one of the two jumps, or on to the call
                if (i + 2 < code.len) {
                    visit(gpa, depth, &work, i + 2 + argSBx(code[idx + 1]), dv + 1);
                    visit(gpa, depth, &work, i + 3 + argSBx(code[idx + 2]), dv + 1);
                    visit(gpa, depth, &work, i + 3, dv);
                }
                max = @max(max, dv + 1);
                next = false;
            },
            .call => delta = -@as(i32, @intCast(argBx(ins))),
            .call_spread => delta = -@as(i32, @intCast(argBx(ins))) - 1,
            .@"return", .throw => next = false,
            .@"test" => {
                delta = -1;
                visit(gpa, depth, &work, i + 2, dv - 1);
            },
            .jump => {
                visit(gpa, depth, &work, i + 1 + argSBx(ins), dv);
                next = false;
            },
            .try_begin => {
                // the handler starts at the try's top with the error on it
                visit(gpa, depth, &work, i + 1 + argSBx(ins), dv + 1);
            },
            .add_x, .sub_x, .mul_x, .div_x, .mod_x, .get_x, .get_k => delta = pushes - popped,
            .set_x, .set_k => delta = -popped - pushes,
            .self_x, .self_k => delta = if (popped != 0) 2 else 3,
            .jlt, .jleq, .jeq, .jtest, .for_loop => {
                // the word after it is a jump, taken or skipped
                const d2 = dv - (if (op == .jtest or op == .for_loop) 0 else popped);
                if (i + 1 < code.len) {
                    const off = argSBx(code[idx + 1]);
                    visit(gpa, depth, &work, i + 2, d2);
                    visit(gpa, depth, &work, i + 2 + off, d2);
                    if (op == .for_loop) visit(gpa, depth, &work, i + 2 + off - 2, d2);
                }
                max = @max(max, d2);
                next = false;
            },
            _ => {},
        }
        const after = dv + delta;
        max = @max(max, @max(dv, after));
        if (next) visit(gpa, depth, &work, i + 1, after);
    }
    return @intCast(max);
}
