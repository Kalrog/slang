//! The register instruction set (plans/PLAN_REGISTER.md): its opcodes, the
//! encoding, and how an instruction is rendered. It runs in
//! interp_reg.zig; a prototype says which ISA its code is in (Proto.isa).
//!
//! 32-bit words, Lua 5.4's layout:
//!
//!   31      24 23      16 15 14       7 6      0
//!   |    C     |    B     |k |    A     |   op   |   ABC (k: C is a constant)
//!   |          Bx (17)       |    A     |   op   |   ABx, AsBx (sBx = Bx - 65535)
//!   |              Ax (25)              |   op   |   Ax
//!
//! R[x] is register x of the frame (its locals and temporaries: base + x),
//! K[x] constant x, U[x] upvalue x, RK(C) K[C] when k is set, else R[C].
//!
//! A call's function and arguments are the highest registers in use at the
//! call: what is above them is dead (the callee's frame starts at R[A+1],
//! and the collector clears the stack above the top in its atomic phase).
//!
//! Compare and test instructions are followed by a jump: they skip it when
//! the condition differs from what they expect, and take it otherwise (the
//! interpreter takes a forward one at once).

const std = @import("std");
const root = @import("../vm.zig");
const Proto = root.Proto;
const Writer = std.Io.Writer;

pub const Op = enum(u7) {
    // ---- loads
    move = 0, // R[A] = R[B]
    load_k, // R[A] = K[Bx]
    load_int, // R[A] = sBx
    load_bool, // R[A] = B != 0; if C: pc++
    load_null, // R[A], ..., R[A+B] = null
    closure, // R[A] = closure(children[Bx])
    // ---- upvalues
    get_upval, // R[A] = U[B]
    set_upval, // U[B] = R[A]
    close, // close the upvalues of R[A] and above
    // ---- arithmetic: R[A] = R[B] op RK(C)
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
    // ---- unary: R[A] = op R[B]
    neg,
    not,
    bnot,
    // ---- compare, then a jump: if (R[B] op RK(C)) != (A != 0): pc++
    eq,
    lt,
    le,
    gt, // R[B] > RK(C), as RK(C) < R[B] (__lt with the operands swapped)
    ge, // R[B] >= RK(C), as RK(C) <= R[B]
    // ---- tests, then a jump
    @"test", // if truthy(R[A]) != k: pc++
    test_set, // if truthy(R[B]) != k: pc++ else R[A] = R[B]
    jump, // pc += sBx (backward: a safe point)
    // ---- tables
    new_table, // R[A] = {} (B array hint, C hash hint)
    get_field, // R[A] = R[B][K[C]]
    get_index, // R[A] = R[B][R[C]]
    get_up_field, // R[A] = U[B][K[C]]
    set_field, // R[A][K[B]] = RK(C)
    set_index, // R[A][R[B]] = RK(C)
    set_up_field, // U[A][K[B]] = RK(C)
    self, // R[A+1] = R[B]; R[A] = R[B][RK(C)]
    set_list, // R[A][n + i] = R[A+1+i] for i < B; n = C, or with k the next word
    // R[A][K[B]] = RK(C) into a table literal being built (R[A] new, no
    // metatable: a raw store, never quickened; the keys are new)
    init_field,
    // ---- metatables, types
    get_meta, // R[A] = R[B].@meta
    set_meta, // R[A].@meta = R[B]
    type, // R[A] = type(R[B])
    // ---- functions
    call, // R[A] = R[A](R[A+1], ..., R[A+B])
    call_spread, // as call, then the elements of the list in R[A+B+1]
    @"return", // return R[A]
    return_null, // return null
    // ---- errors
    try_begin, // a handler at pc + sBx: on an error R[A] = the error, upvalues from R[A] closed
    try_end, // pop the innermost handler
    throw, // raise R[A]
    // ---- loops
    // R[A] += R[B] (or K[B], or -=), compared with R[C] (or K[C]): the next
    // word is the jump to the body, its A the flags (for_flags)
    for_loop,
    // R[A] = f, R[A+1] = x: when f is the built-in keys, values or entries
    // and x a table, R[A] = x and R[A+1] the position; else R[A] = f(x)
    forin_prep,
    // the next two words are jumps: the loop's end and its pattern. A table
    // in R[A] (forin_prep) puts its next element in R[A+2] and takes the
    // second (the first at the end); a function skips both, to its call
    forin_next,

    // The quickened forms (inside the VM only: never in bytecode files,
    // see Proto.original). The key operand is an inline cache in Proto.ics:
    // C + k * 256 for the loads, B for set_field_q.
    get_field_q = 124,
    get_up_field_q = 125,
    self_q = 126,
    set_field_q = 127,
    _,

    pub fn name(op: Op) []const u8 {
        return switch (op) {
            .move => "move",
            .load_k => "loadK",
            .load_int => "loadInt",
            .load_bool => "loadBool",
            .load_null => "loadNull",
            .closure => "closure",
            .get_upval => "getUpval",
            .set_upval => "setUpval",
            .close => "close",
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "mod",
            .pow => "pow",
            .band => "band",
            .bor => "bor",
            .bxor => "bxor",
            .shl => "shl",
            .shr => "shr",
            .neg => "neg",
            .not => "not",
            .bnot => "bnot",
            .eq => "eq",
            .lt => "lt",
            .le => "le",
            .gt => "gt",
            .ge => "ge",
            .@"test" => "test",
            .test_set => "testSet",
            .jump => "jump",
            .new_table => "newTable",
            .get_field => "getField",
            .get_index => "getIndex",
            .get_up_field => "getUpField",
            .set_field => "setField",
            .set_index => "setIndex",
            .set_up_field => "setUpField",
            .self => "self",
            .set_list => "setList",
            .init_field => "initField",
            .get_meta => "getMeta",
            .set_meta => "setMeta",
            .type => "type",
            .call => "call",
            .call_spread => "callSpread",
            .@"return" => "return",
            .return_null => "returnNull",
            .try_begin => "tryBegin",
            .try_end => "tryEnd",
            .throw => "throw",
            .for_loop => "forLoop",
            .forin_prep => "forinPrep",
            .forin_next => "forinNext",
            .get_field_q => "getFieldQ",
            .get_up_field_q => "getUpFieldQ",
            .self_q => "selfQ",
            .set_field_q => "setFieldQ",
            _ => "op?",
        };
    }
};

/// The number of opcodes the encoding has room for.
pub const count = 128;

/// The flags of a for_loop, in the A of the jump word after it.
pub const for_flags = struct {
    pub const leq = 1; // the condition is <= (else <)
    pub const negate = 2; // the loop goes on while the condition is false
    pub const sub = 4; // the update subtracts the step
    pub const step_k = 8; // the step is K[B] (else R[B])
    pub const limit_k = 16; // the limit is K[C] (else R[C])
};

/// The most inline caches a prototype's quickened loads can address (C and
/// k), and its quickened stores (B).
pub const max_load_caches = 512;
pub const max_store_caches = 256;

pub const max_bx = (1 << 17) - 1;
pub const sbx_bias = 65535;

pub inline fn opOf(ins: u32) Op {
    return @fromBackingInt(@intCast(@as(u7, @truncate(ins))));
}
pub inline fn argA(ins: u32) u32 {
    return (ins >> 7) & 0xFF;
}
pub inline fn argK(ins: u32) bool {
    return (ins >> 15) & 1 != 0;
}
pub inline fn argB(ins: u32) u32 {
    return (ins >> 16) & 0xFF;
}
pub inline fn argC(ins: u32) u32 {
    return ins >> 24;
}
pub inline fn argBx(ins: u32) u32 {
    return ins >> 15;
}
pub inline fn argSBx(ins: u32) i32 {
    return @as(i32, @intCast(ins >> 15)) - sbx_bias;
}
pub inline fn argAx(ins: u32) u32 {
    return ins >> 7;
}

pub fn abc(op: Op, a: u32, b: u32, c: u32, k: bool) u32 {
    std.debug.assert(a <= 0xFF and b <= 0xFF and c <= 0xFF);
    return @backingInt(op) | a << 7 | @as(u32, @intFromBool(k)) << 15 | b << 16 | c << 24;
}
pub fn abx(op: Op, a: u32, bx: u32) u32 {
    std.debug.assert(a <= 0xFF and bx <= max_bx);
    return @backingInt(op) | a << 7 | bx << 15;
}
pub fn asbx(op: Op, a: u32, sbx: i32) u32 {
    return abx(op, a, @intCast(sbx + sbx_bias));
}
pub fn ax(op: Op, a: u32) u32 {
    return @backingInt(op) | a << 7;
}

pub inline fn isQuickened(op: Op) bool {
    return @backingInt(op) >= @backingInt(Op.get_field_q);
}

/// The inline cache of a quickened instruction.
pub inline fn cacheOf(ins: u32) u32 {
    return if (opOf(ins) == .set_field_q) argB(ins) else argC(ins) | @as(u32, @intFromBool(argK(ins))) << 8;
}

const Mode = enum { abc, abck, abx, asbx, a, ak, ab, none, jump };

fn mode(op: Op) Mode {
    return switch (op) {
        .load_k, .closure => .abx,
        .load_int, .try_begin => .asbx,
        .jump => .jump,
        .close, .@"return", .throw, .forin_prep, .forin_next => .a,
        .move, .load_null, .get_upval, .set_upval, .neg, .not, .bnot, .get_meta, .set_meta, .type, .call, .call_spread => .ab,
        .return_null, .try_end => .none,
        .@"test" => .ak,
        .add, .sub, .mul, .div, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .eq, .lt, .le, .gt, .ge, .set_field, .set_index, .set_up_field, .self, .set_list, .init_field, .test_set => .abck,
        else => .abc,
    };
}

/// Renders one instruction.
pub fn writeInstruction(w: *Writer, ins: u32) Writer.Error!void {
    const op = opOf(ins);
    const name = op.name();
    switch (mode(op)) {
        .abc => try w.print("{s} {d} {d} {d}", .{ name, argA(ins), argB(ins), argC(ins) }),
        .abck => try w.print("{s} {d} {d} {d}{s}", .{ name, argA(ins), argB(ins), argC(ins), if (argK(ins)) "k" else "" }),
        .abx => try w.print("{s} {d} {d}", .{ name, argA(ins), argBx(ins) }),
        .asbx => try w.print("{s} {d} {d}", .{ name, argA(ins), argSBx(ins) }),
        .jump => try w.print("{s} {d}", .{ name, argSBx(ins) }),
        .a => try w.print("{s} {d}", .{ name, argA(ins) }),
        .ak => try w.print("{s} {d}{s}", .{ name, argA(ins), if (argK(ins)) " k" else "" }),
        .ab => try w.print("{s} {d} {d}", .{ name, argA(ins), argB(ins) }),
        .none => try w.writeAll(name),
    }
}

/// What an instruction refers to, for the reader: constants, upvalue
/// names, jump targets.
pub fn annotate(w: *Writer, p: *const Proto, pc: usize, ins: u32) Writer.Error!void {
    const a = argA(ins);
    const b = argB(ins);
    const c = argC(ins);
    const k = argK(ins);
    switch (opOf(ins)) {
        .load_k => try constant(w, p, argBx(ins)),
        .load_bool => {
            try w.writeAll(if (b != 0) "true" else "false");
            if (c != 0) try w.writeAll(", skip next");
        },
        .load_null => try w.print("{d} register{s}", .{ b + 1, if (b == 0) "" else "s" }),
        .closure => {
            const idx = argBx(ins);
            if (idx < p.children.len) {
                const ch = p.children[idx];
                try w.print("function #{d} (nargs={d}{s})", .{ idx, ch.nargs, if (ch.is_vararg) " vararg" else "" });
            }
        },
        .get_upval, .set_upval => try upvalue(w, p, b),
        .close => try w.print("from r{d}", .{a}),
        .add, .sub, .mul, .div, .mod, .pow, .band, .bor, .bxor, .shl, .shr, .self, .set_field, .init_field, .set_index, .set_up_field => {
            switch (opOf(ins)) {
                .set_field, .init_field => {
                    try constant(w, p, b);
                    if (k) try w.writeAll(" = ");
                },
                .set_up_field => {
                    try upvalue(w, p, a);
                    try w.writeAll(".");
                    try constant(w, p, b);
                    if (k) try w.writeAll(" = ");
                },
                else => {},
            }
            if (k) try constant(w, p, c);
        },
        .eq, .lt, .le, .gt, .ge => {
            if (k) {
                try constant(w, p, c);
                try w.writeAll("; ");
            }
            try w.writeAll(if (a != 0) "skip next when false" else "skip next when true");
        },
        .@"test" => try w.writeAll(if (k) "skip next when false" else "skip next when true"),
        .test_set => try w.writeAll(if (k) "skip next when false, else move" else "skip next when true, else move"),
        .jump => try w.print("-> {d}", .{@as(i64, @intCast(pc)) + 1 + argSBx(ins)}),
        .try_begin => try w.print("handler -> {d}, error in r{d}", .{ @as(i64, @intCast(pc)) + 1 + argSBx(ins), a }),
        .new_table => try w.print("array {d}, hash {d}", .{ b, c }),
        .get_field => try constant(w, p, c),
        .get_up_field => {
            try upvalue(w, p, b);
            try w.writeAll(".");
            try constant(w, p, c);
        },
        .set_list => if (!k) try w.print("from {d}", .{c}),
        .call => try w.print("{d} arg{s}", .{ b, if (b == 1) "" else "s" }),
        .call_spread => try w.print("{d} fixed args and a list", .{b}),
        .for_loop => if (pc + 1 < p.code.len) {
            const j = p.code[pc + 1];
            const f = argA(j);
            try w.print("{s} {s}{s}, body -> {d}", .{
                if (f & for_flags.sub != 0) "-=" else "+=",
                if (f & for_flags.negate != 0) "until " else "while ",
                if (f & for_flags.leq != 0) "<=" else "<",
                @as(i64, @intCast(pc)) + 2 + argSBx(j),
            });
        },
        else => {},
    }
}

fn constant(w: *Writer, p: *const Proto, idx: u32) Writer.Error!void {
    if (idx >= p.consts.len) return;
    const v = p.consts[idx];
    if (v == .string) {
        const s = v.string.bytes();
        try w.writeByte('"');
        try w.writeAll(s[0..@min(s.len, 40)]);
        try w.writeByte('"');
        if (s.len > 40) try w.print("... ({d} bytes)", .{s.len});
    } else {
        try root.format.writeValue(w, v);
    }
}

fn upvalue(w: *Writer, p: *const Proto, idx: u32) Writer.Error!void {
    if (idx < p.upvals.len) try w.writeAll(p.upvals[idx].name.bytes());
}
