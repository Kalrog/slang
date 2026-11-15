//! The kernel JIT for the browser: kernel bytecode to a WebAssembly
//! function, which the browser compiles to machine code. It has the
//! interpreter's entry signature and stands in for jit.zig in the
//! Emscripten build (the graphics VM, website/web/build.sh).
//!
//! The design, in one paragraph. A program becomes a module of its own with
//! one exported function, run(I, F, slots, out) -> i32, that imports the
//! VM's memory, so its loads and stores reach the same arrays the
//! interpreter's would. Every register the program uses is a local (i64 or
//! f64), loaded from the register arrays on entry (where the constants and
//! arguments are); a return stores its register back. Control flow: the
//! code is cut into basic blocks, laid out in order inside nested wasm
//! blocks in one loop. A jump forward leaves the blocks up to its target
//! (a plain `br`); a jump back sets the label local and goes round the loop
//! to a `br_table`, which enters the target. Bounds and division checks
//! fill the Outcome exactly as the interpreter does. The functions of libm
//! (sin, pow, round, ...) are the VM's own, imported by name. web.c
//! instantiates the module and puts its function in the VM's function
//! table: the table index is the function pointer.
const std = @import("std");
const vm = @import("vm.zig");
const Op = vm.Op;

const Allocator = std.mem.Allocator;

pub const Func = *const fn (I: *[256]i64, F: *[256]f64, slots: *const [64]vm.Slot, out: *vm.Outcome) callconv(.c) u8;

pub const Code = struct {
    func: Func,
    index: c_int,
};

pub const Error = error{ OutOfMemory, Unsupported, LoadFailed };

pub const available = true;

// web.c
extern fn kernel_wasm_load(bytes: [*]const u8, len: c_int) c_int;
extern fn kernel_wasm_free(index: c_int) void;

// ------------------------------------------------------------ encoding

const Buf = std.ArrayList(u8);

fn uleb(gpa: Allocator, b: *Buf, v: u64) !void {
    var x = v;
    while (true) {
        const byte: u8 = @truncate(x & 0x7f);
        x >>= 7;
        if (x == 0) {
            try b.append(gpa, byte);
            return;
        }
        try b.append(gpa, byte | 0x80);
    }
}

fn sleb(gpa: Allocator, b: *Buf, v: i64) !void {
    var x = v;
    while (true) {
        const byte: u8 = @truncate(@as(u64, @bitCast(x)) & 0x7f);
        x >>= 7;
        const done = (x == 0 and byte & 0x40 == 0) or (x == -1 and byte & 0x40 != 0);
        if (done) {
            try b.append(gpa, byte);
            return;
        }
        try b.append(gpa, byte | 0x80);
    }
}

// opcodes
const W = struct {
    const @"unreachable" = 0x00;
    const block = 0x02;
    const loop = 0x03;
    const @"if" = 0x04;
    const @"else" = 0x05;
    const end = 0x0b;
    const br = 0x0c;
    const br_if = 0x0d;
    const br_table = 0x0e;
    const @"return" = 0x0f;
    const call = 0x10;
    const select = 0x1b;
    const local_get = 0x20;
    const local_set = 0x21;
    const local_tee = 0x22;
    const i32_load = 0x28;
    const i64_load = 0x29;
    const f32_load = 0x2a;
    const f64_load = 0x2b;
    const i32_load8_u = 0x2d;
    const i64_load8_s = 0x30;
    const i64_load8_u = 0x31;
    const i64_load16_s = 0x32;
    const i64_load16_u = 0x33;
    const i64_load32_s = 0x34;
    const i64_load32_u = 0x35;
    const i32_store = 0x36;
    const i64_store = 0x37;
    const f32_store = 0x38;
    const f64_store = 0x39;
    const i32_store8 = 0x3a;
    const i64_store8 = 0x3c;
    const i64_store16 = 0x3d;
    const i64_store32 = 0x3e;
    const i32_const = 0x41;
    const i64_const = 0x42;
    const f64_const = 0x44;
    const i32_eqz = 0x45;
    const i32_ne = 0x47;
    const i64_eqz = 0x50;
    const i64_eq = 0x51;
    const i64_ne = 0x52;
    const i64_lt_s = 0x53;
    const i64_gt_s = 0x55;
    const i64_le_s = 0x57;
    const i64_ge_s = 0x59;
    const i64_ge_u = 0x5a;
    const f64_eq = 0x61;
    const f64_ne = 0x62;
    const f64_lt = 0x63;
    const f64_gt = 0x64;
    const f64_le = 0x65;
    const i32_add = 0x6a;
    const i32_mul = 0x6c;
    const i32_and = 0x71;
    const i64_add = 0x7c;
    const i64_sub = 0x7d;
    const i64_mul = 0x7e;
    const i64_div_s = 0x7f;
    const i64_rem_s = 0x81;
    const i64_and = 0x83;
    const i64_or = 0x84;
    const i64_xor = 0x85;
    const i64_shl = 0x86;
    const i64_shr_s = 0x87;
    const f64_abs = 0x99;
    const f64_neg = 0x9a;
    const f64_ceil = 0x9b;
    const f64_floor = 0x9c;
    const f64_trunc = 0x9d;
    const f64_sqrt = 0x9f;
    const f64_add = 0xa0;
    const f64_sub = 0xa1;
    const f64_mul = 0xa2;
    const f64_div = 0xa3;
    const i32_wrap_i64 = 0xa7;
    const i64_extend_i32_u = 0xad;
    const f32_demote_f64 = 0xb6;
    const f64_convert_i64_s = 0xb9;
    const f64_promote_f32 = 0xbb;
    const prefix_fc = 0xfc;
    const i64_trunc_sat_f64_s = 0x06;
};

const T_I32 = 0x7f;
const T_I64 = 0x7e;
const T_F64 = 0x7c;
const T_VOID = 0x40;

// the functions of libm the code may call, by name; arity 1 or 2
const Math = enum { sin, cos, tan, asin, acos, atan, exp, exp2, log, log2, tanh, sinh, cosh, round, pow, atan2 };

fn mathOf(op: Op) ?Math {
    return switch (op) {
        .sin => .sin,
        .cos => .cos,
        .tan => .tan,
        .asin => .asin,
        .acos => .acos,
        .atan => .atan,
        .exp => .exp,
        .exp2 => .exp2,
        .log => .log,
        .log2 => .log2,
        .tanh => .tanh,
        .sinh => .sinh,
        .cosh => .cosh,
        .round => .round,
        .powf => .pow,
        .atan2 => .atan2,
        else => null,
    };
}

const slot_size = @sizeOf(vm.Slot);
const slot_base = @offsetOf(vm.Slot, "base");
const slot_len = @offsetOf(vm.Slot, "len");
const out_fault = @offsetOf(vm.Outcome, "fault");
const out_pc = @offsetOf(vm.Outcome, "pc");
const out_index = @offsetOf(vm.Outcome, "index");
const out_len = @offsetOf(vm.Outcome, "len");

// the parameters' locals
const L_I = 0;
const L_F = 1;
const L_SLOTS = 2;
const L_OUT = 3;

const NONE = std.math.maxInt(u32);

const Compiler = struct {
    gpa: Allocator,
    p: *const vm.Program,
    stride: [64]u32,
    b: Buf = .empty,
    // locals: a register's, a slot's base and length, scratch
    li: [256]u32 = @splat(NONE),
    lf: [256]u32 = @splat(NONE),
    lbase: [64]u32 = @splat(NONE),
    llen: [64]u32 = @splat(NONE),
    l_label: u32 = 0,
    t_i64: [3]u32 = undefined,
    // the imports the code calls, and their function indices
    math_index: [@typeInfo(Math).@"enum".field_names.len]u32 = @splat(NONE),
    math_count: u32 = 0,
    // basic blocks: the pc each starts at, and each pc's block
    starts: std.ArrayList(u32) = .empty,
    block_of: []u32 = &.{},
    // the structured layout: the labels open where the code is, the last
    // block of the loop each block heads (NONE: none), the blocks a jump
    // forward reaches; false: the dispatch layout (see body)
    structured: bool = false,
    labels: std.ArrayList(Label) = .empty,
    loop_end: []u32 = &.{},
    forward: []bool = &.{},

    const Label = struct { loop: bool, at: u32 };

    fn deinit(c: *Compiler) void {
        c.b.deinit(c.gpa);
        c.starts.deinit(c.gpa);
        c.gpa.free(c.block_of);
        c.labels.deinit(c.gpa);
        c.gpa.free(c.loop_end);
        c.gpa.free(c.forward);
    }

    /// The depth of the label a jump to block `to` takes: the loop it heads
    /// (back) or the block that ends where it starts (forward).
    fn depthOf(c: *Compiler, loop: bool, to: u32) Error!u32 {
        var i = c.labels.items.len;
        while (i > 0) {
            i -= 1;
            const l = c.labels.items[i];
            if (l.loop == loop and l.at == to) return @intCast(c.labels.items.len - 1 - i);
        }
        return error.Unsupported;
    }

    fn byte(c: *Compiler, x: u8) !void {
        try c.b.append(c.gpa, x);
    }
    fn u(c: *Compiler, x: u64) !void {
        try uleb(c.gpa, &c.b, x);
    }
    fn get(c: *Compiler, l: u32) !void {
        try c.byte(W.local_get);
        try c.u(l);
    }
    fn set(c: *Compiler, l: u32) !void {
        try c.byte(W.local_set);
        try c.u(l);
    }
    fn tee(c: *Compiler, l: u32) !void {
        try c.byte(W.local_tee);
        try c.u(l);
    }
    fn i32c(c: *Compiler, x: i32) !void {
        try c.byte(W.i32_const);
        try sleb(c.gpa, &c.b, x);
    }
    fn i64c(c: *Compiler, x: i64) !void {
        try c.byte(W.i64_const);
        try sleb(c.gpa, &c.b, x);
    }
    fn f64c(c: *Compiler, x: f64) !void {
        try c.byte(W.f64_const);
        const bytes: [8]u8 = @bitCast(x);
        try c.b.appendSlice(c.gpa, &bytes);
    }
    /// a memory access: alignment hint 0 (any), offset
    fn mem(c: *Compiler, op: u8, offset: u64) !void {
        try c.byte(op);
        try c.u(0);
        try c.u(offset);
    }
    fn gi(c: *Compiler, r: u8) !void {
        try c.get(c.li[r]);
    }
    fn gf(c: *Compiler, r: u8) !void {
        try c.get(c.lf[r]);
    }
    fn si(c: *Compiler, r: u8) !void {
        try c.set(c.li[r]);
    }
    fn sf(c: *Compiler, r: u8) !void {
        try c.set(c.lf[r]);
    }
    fn callMath(c: *Compiler, m: Math) !void {
        try c.byte(W.call);
        try c.u(c.math_index[@intFromEnum(m)]);
    }

    // ------------------------------------------------ planning

    fn useI(c: *Compiler, r: u8) void {
        if (c.li[r] == NONE) c.li[r] = 0;
    }
    fn useF(c: *Compiler, r: u8) void {
        if (c.lf[r] == NONE) c.lf[r] = 0;
    }
    fn useSlot(c: *Compiler, s: u8) void {
        c.lbase[s] = 0;
        c.llen[s] = 0;
    }

    /// Which registers, slots and imports the code uses, and where its
    /// basic blocks start.
    fn plan(c: *Compiler) !void {
        const code = c.p.code;
        const leader = try c.gpa.alloc(bool, code.len + 1);
        defer c.gpa.free(leader);
        @memset(leader, false);
        leader[0] = true;
        var pc: u32 = 0;
        while (pc < code.len) {
            const w = code[pc];
            const op: Op = @enumFromInt(@as(u8, @truncate(w)));
            const a = vm.ra(w);
            const b = vm.rb(w);
            const cc = vm.rc(w);
            const size: u32 = if (vm.hasWord(op)) 2 else 1;
            if (mathOf(op)) |m| {
                if (c.math_index[@intFromEnum(m)] == NONE) {
                    c.math_index[@intFromEnum(m)] = c.math_count;
                    c.math_count += 1;
                }
            }
            switch (op) {
                .nop, .ret => {},
                .movi, .negi, .noti, .notb, .absi, .signi => {
                    c.useI(a);
                    c.useI(b);
                },
                .movf, .negf, .sin, .cos, .tan, .asin, .acos, .atan, .exp, .exp2, .log, .log2, .sqrt, .absf, .floor, .ceil, .round, .trunc, .fract, .tanh, .sinh, .cosh, .signf => {
                    c.useF(a);
                    c.useF(b);
                },
                .addi, .subi, .muli, .divi, .modi, .andi, .ori, .xori, .shli, .shri, .lti, .lei, .eqi, .nei, .mini, .maxi => {
                    c.useI(a);
                    c.useI(b);
                    c.useI(cc);
                },
                .addf, .subf, .mulf, .divf, .modf, .powf, .atan2, .minf, .maxf => {
                    c.useF(a);
                    c.useF(b);
                    c.useF(cc);
                },
                .madf => {
                    c.useF(a);
                    c.useF(b);
                    c.useF(cc);
                    c.useF(@truncate(code[pc + 1]));
                },
                .itof => {
                    c.useF(a);
                    c.useI(b);
                },
                .ftoi => {
                    c.useI(a);
                    c.useF(b);
                },
                .ltf, .lef, .eqf, .nef => {
                    c.useI(a);
                    c.useF(b);
                    c.useF(cc);
                },
                .jmp => {},
                .jt, .jf => c.useI(a),
                .jlti, .jlei, .jeqi, .jnei => {
                    c.useI(a);
                    c.useI(b);
                },
                .jltf, .jlef, .jeqf, .jnef, .jnltf, .jnlef => {
                    c.useF(a);
                    c.useF(b);
                },
                .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei => {
                    c.useI(a);
                    c.useI(b);
                    c.useI(cc);
                },
                .seli => {
                    c.useI(a);
                    c.useI(b);
                    c.useI(cc);
                    c.useI(@truncate(code[pc + 1] & 0xff));
                },
                .self => {
                    c.useF(a);
                    c.useF(b);
                    c.useF(cc);
                    c.useI(@truncate(code[pc + 1] & 0xff));
                },
                .len => {
                    c.useI(a);
                    c.useSlot(b);
                },
                .reti => c.useI(a),
                .retf => c.useF(a),
                .ld_float, .ld_double => {
                    c.useF(a);
                    c.useSlot(b);
                    c.useI(cc);
                },
                .ld_int8, .ld_uint8, .ld_int16, .ld_uint16, .ld_int32, .ld_uint32, .ld_int64, .ld_uint64, .ld_bool => {
                    c.useI(a);
                    c.useSlot(b);
                    c.useI(cc);
                },
                .st_float, .st_double => {
                    c.useSlot(a);
                    c.useI(b);
                    c.useF(cc);
                },
                .st_int8, .st_uint8, .st_int16, .st_uint16, .st_int32, .st_uint32, .st_int64, .st_uint64, .st_bool => {
                    c.useSlot(a);
                    c.useI(b);
                    c.useI(cc);
                },
            }
            if (vm.isJump(op)) {
                leader[code[pc + 1]] = true;
                leader[pc + size] = true;
            }
            if (op == .ret or op == .reti or op == .retf) leader[pc + size] = true;
            pc += size;
        }
        c.block_of = try c.gpa.alloc(u32, code.len);
        pc = 0;
        while (pc < code.len) {
            if (leader[pc]) try c.starts.append(c.gpa, pc);
            c.block_of[pc] = @intCast(c.starts.items.len - 1);
            const op: Op = @enumFromInt(@as(u8, @truncate(code[pc])));
            pc += if (vm.hasWord(op)) 2 else 1;
        }
    }

    // ------------------------------------------------ the body

    /// The locals after the four parameters, in groups of one type, and
    /// their declarations.
    fn locals(c: *Compiler, out: *Buf) !void {
        var next: u32 = 4;
        var n_i64: u32 = 0;
        var n_f64: u32 = 0;
        var n_i32: u32 = 0;
        for (&c.li) |*l| if (l.* != NONE) {
            l.* = next;
            next += 1;
            n_i64 += 1;
        };
        for (&c.llen) |*l| if (l.* != NONE) {
            l.* = next;
            next += 1;
            n_i64 += 1;
        };
        for (&c.t_i64) |*l| {
            l.* = next;
            next += 1;
            n_i64 += 1;
        }
        for (&c.lf) |*l| if (l.* != NONE) {
            l.* = next;
            next += 1;
            n_f64 += 1;
        };
        for (&c.lbase) |*l| if (l.* != NONE) {
            l.* = next;
            next += 1;
            n_i32 += 1;
        };
        c.l_label = next;
        n_i32 += 1;
        // three groups
        try uleb(c.gpa, out, 3);
        try uleb(c.gpa, out, n_i64);
        try out.append(c.gpa, T_I64);
        try uleb(c.gpa, out, n_f64);
        try out.append(c.gpa, T_F64);
        try uleb(c.gpa, out, n_i32);
        try out.append(c.gpa, T_I32);
    }

    fn prologue(c: *Compiler) !void {
        for (c.li, 0..) |l, r| if (l != NONE) {
            try c.get(L_I);
            try c.mem(W.i64_load, r * 8);
            try c.set(l);
        };
        for (c.lf, 0..) |l, r| if (l != NONE) {
            try c.get(L_F);
            try c.mem(W.f64_load, r * 8);
            try c.set(l);
        };
        for (c.lbase, 0..) |l, s| if (l != NONE) {
            try c.get(L_SLOTS);
            try c.mem(W.i32_load, s * slot_size + slot_base);
            try c.set(l);
            try c.get(L_SLOTS);
            try c.mem(W.i64_load, s * slot_size + slot_len);
            try c.set(c.llen[s]);
        };
    }

    /// out.fault = kind, out.pc = pc; return 0 (index and length set
    /// before, for an index fault)
    fn fault(c: *Compiler, kind: vm.Fault, pc: u32) !void {
        try c.get(L_OUT);
        try c.i32c(@intFromEnum(kind));
        try c.mem(W.i32_store8, out_fault);
        try c.get(L_OUT);
        try c.i32c(@bitCast(pc));
        try c.mem(W.i32_store, out_pc);
        try c.i32c(0);
        try c.byte(W.@"return");
    }

    /// Leaves the code of block `from` for the start of block `to`; depth
    /// counts the constructs opened inside the block's code (an if).
    fn jump(c: *Compiler, from: u32, to: u32, depth: u32) !void {
        if (c.structured) {
            try c.byte(W.br);
            try c.u(try c.depthOf(to <= from, to) + depth);
            return;
        }
        const n: u32 = @intCast(c.starts.items.len);
        if (to > from) {
            try c.byte(W.br);
            try c.u(to - from - 1 + depth);
        } else {
            try c.i32c(@intCast(to));
            try c.set(c.l_label);
            try c.byte(W.br);
            try c.u(n - 1 - from + depth);
        }
    }

    /// A conditional jump: the condition (an i32) is on the stack.
    fn jumpIf(c: *Compiler, from: u32, to: u32) !void {
        if (c.structured) {
            try c.byte(W.br_if);
            try c.u(try c.depthOf(to <= from, to));
            return;
        }
        const n: u32 = @intCast(c.starts.items.len);
        if (to > from) {
            try c.byte(W.br_if);
            try c.u(to - from - 1);
        } else {
            try c.byte(W.@"if");
            try c.byte(T_VOID);
            try c.i32c(@intCast(to));
            try c.set(c.l_label);
            try c.byte(W.br);
            try c.u(n - 1 - from + 1);
            try c.byte(W.end);
        }
    }

    /// The address of slot s's element at the index in register x, checked
    /// (an index fault at pc otherwise), on the stack as an i32.
    fn address(c: *Compiler, s: u8, x: u8, pc: u32) !void {
        try c.gi(x);
        try c.get(c.llen[s]);
        try c.byte(W.i64_ge_u);
        try c.byte(W.@"if");
        try c.byte(T_VOID);
        try c.get(L_OUT);
        try c.gi(x);
        try c.mem(W.i64_store, out_index);
        try c.get(L_OUT);
        try c.get(c.llen[s]);
        try c.mem(W.i64_store, out_len);
        try c.fault(.index, pc);
        try c.byte(W.end);
        try c.get(c.lbase[s]);
        try c.gi(x);
        try c.byte(W.i32_wrap_i64);
        if (c.stride[s] != 0) {
            try c.i32c(@intCast(c.stride[s]));
        } else {
            try c.get(L_SLOTS);
            try c.mem(W.i32_load, @as(u64, s) * slot_size + @offsetOf(vm.Slot, "stride"));
        }
        try c.byte(W.i32_mul);
        try c.byte(W.i32_add);
    }

    fn binI(c: *Compiler, w: u32, op: u8) !void {
        try c.gi(vm.rb(w));
        try c.gi(vm.rc(w));
        try c.byte(op);
        try c.si(vm.ra(w));
    }
    fn binF(c: *Compiler, w: u32, op: u8) !void {
        try c.gf(vm.rb(w));
        try c.gf(vm.rc(w));
        try c.byte(op);
        try c.sf(vm.ra(w));
    }
    fn cmpI(c: *Compiler, w: u32, op: u8) !void {
        try c.gi(vm.rb(w));
        try c.gi(vm.rc(w));
        try c.byte(op);
        try c.byte(W.i64_extend_i32_u);
        try c.si(vm.ra(w));
    }
    fn cmpF(c: *Compiler, w: u32, op: u8) !void {
        try c.gf(vm.rb(w));
        try c.gf(vm.rc(w));
        try c.byte(op);
        try c.byte(W.i64_extend_i32_u);
        try c.si(vm.ra(w));
    }

    fn instruction(c: *Compiler, pc: u32) !void {
        const code = c.p.code;
        const w = code[pc];
        const op: Op = @enumFromInt(@as(u8, @truncate(w)));
        const a = vm.ra(w);
        const b = vm.rb(w);
        const cc = vm.rc(w);
        const here = c.block_of[pc];
        const t0 = c.t_i64[0];
        const t1 = c.t_i64[1];
        const t2 = c.t_i64[2];
        switch (op) {
            .nop => {},
            .movi => {
                try c.gi(b);
                try c.si(a);
            },
            .movf => {
                try c.gf(b);
                try c.sf(a);
            },
            .addi => try c.binI(w, W.i64_add),
            .subi => try c.binI(w, W.i64_sub),
            .muli => try c.binI(w, W.i64_mul),
            .andi => try c.binI(w, W.i64_and),
            .ori => try c.binI(w, W.i64_or),
            .xori => try c.binI(w, W.i64_xor),
            .shli => try c.binI(w, W.i64_shl),
            .shri => try c.binI(w, W.i64_shr_s),
            .divi, .modi => {
                // y = I[c]: zero faults
                try c.gi(cc);
                try c.tee(t1);
                try c.byte(W.i64_eqz);
                try c.byte(W.@"if");
                try c.byte(T_VOID);
                try c.fault(.divide, pc);
                try c.byte(W.end);
                try c.gi(b);
                try c.set(t0);
                // y == -1: -x, or 0 (wasm traps on minInt / -1)
                try c.get(t1);
                try c.i64c(-1);
                try c.byte(W.i64_eq);
                try c.byte(W.@"if");
                try c.byte(T_I64);
                if (op == .divi) {
                    try c.i64c(0);
                    try c.get(t0);
                    try c.byte(W.i64_sub);
                } else {
                    try c.i64c(0);
                }
                try c.byte(W.@"else");
                if (op == .divi) {
                    // q - 1 when the remainder is not 0 and the signs differ
                    try c.get(t0);
                    try c.get(t1);
                    try c.byte(W.i64_div_s);
                    try c.tee(t2);
                    try c.i64c(1);
                    try c.byte(W.i64_sub);
                    try c.get(t2);
                    try c.get(t0);
                    try c.get(t2);
                    try c.get(t1);
                    try c.byte(W.i64_mul);
                    try c.byte(W.i64_sub);
                    try c.i64c(0);
                    try c.byte(W.i64_ne);
                    try c.get(t0);
                    try c.i64c(0);
                    try c.byte(W.i64_lt_s);
                    try c.get(t1);
                    try c.i64c(0);
                    try c.byte(W.i64_lt_s);
                    try c.byte(W.i32_ne);
                    try c.byte(W.i32_and);
                    try c.byte(W.select);
                } else {
                    // r + y when r is not 0 and its sign is not y's
                    try c.get(t0);
                    try c.get(t1);
                    try c.byte(W.i64_rem_s);
                    try c.tee(t2);
                    try c.get(t1);
                    try c.byte(W.i64_add);
                    try c.get(t2);
                    try c.get(t2);
                    try c.i64c(0);
                    try c.byte(W.i64_ne);
                    try c.get(t2);
                    try c.i64c(0);
                    try c.byte(W.i64_lt_s);
                    try c.get(t1);
                    try c.i64c(0);
                    try c.byte(W.i64_lt_s);
                    try c.byte(W.i32_ne);
                    try c.byte(W.i32_and);
                    try c.byte(W.select);
                }
                try c.byte(W.end);
                try c.si(a);
            },
            .negi => {
                try c.i64c(0);
                try c.gi(b);
                try c.byte(W.i64_sub);
                try c.si(a);
            },
            .noti => {
                try c.gi(b);
                try c.i64c(-1);
                try c.byte(W.i64_xor);
                try c.si(a);
            },
            .addf => try c.binF(w, W.f64_add),
            .subf => try c.binF(w, W.f64_sub),
            .mulf => try c.binF(w, W.f64_mul),
            .divf => try c.binF(w, W.f64_div),
            .modf => {
                // x - y * floor(x / y)
                try c.gf(b);
                try c.gf(cc);
                try c.gf(b);
                try c.gf(cc);
                try c.byte(W.f64_div);
                try c.byte(W.f64_floor);
                try c.byte(W.f64_mul);
                try c.byte(W.f64_sub);
                try c.sf(a);
            },
            .negf => {
                try c.gf(b);
                try c.byte(W.f64_neg);
                try c.sf(a);
            },
            .powf, .atan2 => {
                try c.gf(b);
                try c.gf(cc);
                try c.callMath(mathOf(op).?);
                try c.sf(a);
            },
            .madf => {
                try c.gf(b);
                try c.gf(cc);
                try c.gf(@truncate(code[pc + 1]));
                try c.byte(W.f64_mul);
                try c.byte(W.f64_add);
                try c.sf(a);
            },
            .itof => {
                try c.gi(b);
                try c.byte(W.f64_convert_i64_s);
                try c.sf(a);
            },
            .ftoi => {
                // saturating, NaN to 0: the interpreter's toInt
                try c.gf(b);
                try c.byte(W.prefix_fc);
                try c.u(W.i64_trunc_sat_f64_s);
                try c.si(a);
            },
            .lti => try c.cmpI(w, W.i64_lt_s),
            .lei => try c.cmpI(w, W.i64_le_s),
            .eqi => try c.cmpI(w, W.i64_eq),
            .nei => try c.cmpI(w, W.i64_ne),
            .ltf => try c.cmpF(w, W.f64_lt),
            .lef => try c.cmpF(w, W.f64_le),
            .eqf => try c.cmpF(w, W.f64_eq),
            .nef => try c.cmpF(w, W.f64_ne),
            .notb => {
                try c.gi(b);
                try c.byte(W.i64_eqz);
                try c.byte(W.i64_extend_i32_u);
                try c.si(a);
            },
            .jmp => try c.jump(here, c.block_of[code[pc + 1]], 0),
            .jt, .jf => {
                try c.gi(a);
                try c.i64c(0);
                try c.byte(if (op == .jt) W.i64_ne else W.i64_eq);
                try c.jumpIf(here, c.block_of[code[pc + 1]]);
            },
            .jlti, .jlei, .jeqi, .jnei => {
                try c.gi(a);
                try c.gi(b);
                try c.byte(switch (op) {
                    .jlti => W.i64_lt_s,
                    .jlei => W.i64_le_s,
                    .jeqi => W.i64_eq,
                    else => W.i64_ne,
                });
                try c.jumpIf(here, c.block_of[code[pc + 1]]);
            },
            .jltf, .jlef, .jeqf, .jnef, .jnltf, .jnlef => {
                try c.gf(a);
                try c.gf(b);
                try c.byte(switch (op) {
                    .jltf, .jnltf => W.f64_lt,
                    .jlef, .jnlef => W.f64_le,
                    .jeqf => W.f64_eq,
                    else => W.f64_ne,
                });
                if (op == .jnltf or op == .jnlef) try c.byte(W.i32_eqz);
                try c.jumpIf(here, c.block_of[code[pc + 1]]);
            },
            .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei => {
                try c.gi(a);
                try c.gi(b);
                try c.byte(W.i64_add);
                try c.tee(c.li[a]);
                try c.gi(cc);
                try c.byte(switch (op) {
                    .addi_jlti => W.i64_lt_s,
                    .addi_jlei => W.i64_le_s,
                    .addi_jgti => W.i64_gt_s,
                    else => W.i64_ge_s,
                });
                try c.jumpIf(here, c.block_of[code[pc + 1]]);
            },
            .seli => {
                try c.gi(b);
                try c.gi(cc);
                try c.gi(@truncate(code[pc + 1] & 0xff));
                try c.i64c(0);
                try c.byte(W.i64_ne);
                try c.byte(W.select);
                try c.si(a);
            },
            .self => {
                try c.gf(b);
                try c.gf(cc);
                try c.gi(@truncate(code[pc + 1] & 0xff));
                try c.i64c(0);
                try c.byte(W.i64_ne);
                try c.byte(W.select);
                try c.sf(a);
            },
            .len => {
                try c.get(c.llen[b]);
                try c.si(a);
            },
            .sin, .cos, .tan, .asin, .acos, .atan, .exp, .exp2, .log, .log2, .tanh, .sinh, .cosh, .round => {
                try c.gf(b);
                try c.callMath(mathOf(op).?);
                try c.sf(a);
            },
            .sqrt, .absf, .floor, .ceil, .trunc => {
                try c.gf(b);
                try c.byte(switch (op) {
                    .sqrt => W.f64_sqrt,
                    .absf => W.f64_abs,
                    .floor => W.f64_floor,
                    .ceil => W.f64_ceil,
                    else => W.f64_trunc,
                });
                try c.sf(a);
            },
            .fract => {
                try c.gf(b);
                try c.gf(b);
                try c.byte(W.f64_floor);
                try c.byte(W.f64_sub);
                try c.sf(a);
            },
            .signf => {
                // x > 0 ? 1 : (x < 0 ? -1 : x)
                try c.f64c(1);
                try c.f64c(-1);
                try c.gf(b);
                try c.gf(b);
                try c.f64c(0);
                try c.byte(W.f64_lt);
                try c.byte(W.select);
                try c.gf(b);
                try c.f64c(0);
                try c.byte(W.f64_gt);
                try c.byte(W.select);
                try c.sf(a);
            },
            .minf, .maxf => {
                // y < x ? y : x (y > x for max)
                try c.gf(cc);
                try c.gf(b);
                try c.gf(cc);
                try c.gf(b);
                try c.byte(if (op == .minf) W.f64_lt else W.f64_gt);
                try c.byte(W.select);
                try c.sf(a);
            },
            .mini, .maxi => {
                try c.gi(b);
                try c.gi(cc);
                try c.gi(b);
                try c.gi(cc);
                try c.byte(if (op == .mini) W.i64_le_s else W.i64_ge_s);
                try c.byte(W.select);
                try c.si(a);
            },
            .absi => {
                try c.i64c(0);
                try c.gi(b);
                try c.byte(W.i64_sub);
                try c.gi(b);
                try c.gi(b);
                try c.i64c(0);
                try c.byte(W.i64_lt_s);
                try c.byte(W.select);
                try c.si(a);
            },
            .signi => {
                try c.i64c(1);
                try c.i64c(-1);
                try c.i64c(0);
                try c.gi(b);
                try c.i64c(0);
                try c.byte(W.i64_lt_s);
                try c.byte(W.select);
                try c.gi(b);
                try c.i64c(0);
                try c.byte(W.i64_gt_s);
                try c.byte(W.select);
                try c.si(a);
            },
            .ret => {
                try c.i32c(0);
                try c.byte(W.@"return");
            },
            .reti => {
                try c.get(L_I);
                try c.gi(a);
                try c.mem(W.i64_store, @as(u64, a) * 8);
                try c.i32c(a);
                try c.byte(W.@"return");
            },
            .retf => {
                try c.get(L_F);
                try c.gf(a);
                try c.mem(W.f64_store, @as(u64, a) * 8);
                try c.i32c(a);
                try c.byte(W.@"return");
            },
            .ld_float, .ld_double, .ld_int8, .ld_uint8, .ld_int16, .ld_uint16, .ld_int32, .ld_uint32, .ld_int64, .ld_uint64, .ld_bool => {
                try c.address(b, cc, pc);
                const off: u64 = code[pc + 1];
                switch (op) {
                    .ld_float => {
                        try c.mem(W.f32_load, off);
                        try c.byte(W.f64_promote_f32);
                        try c.sf(a);
                    },
                    .ld_double => {
                        try c.mem(W.f64_load, off);
                        try c.sf(a);
                    },
                    .ld_bool => {
                        try c.mem(W.i32_load8_u, off);
                        try c.i32c(0);
                        try c.byte(W.i32_ne);
                        try c.byte(W.i64_extend_i32_u);
                        try c.si(a);
                    },
                    else => {
                        try c.mem(switch (op) {
                            .ld_int8 => W.i64_load8_s,
                            .ld_uint8 => W.i64_load8_u,
                            .ld_int16 => W.i64_load16_s,
                            .ld_uint16 => W.i64_load16_u,
                            .ld_int32 => W.i64_load32_s,
                            .ld_uint32 => W.i64_load32_u,
                            else => W.i64_load,
                        }, off);
                        try c.si(a);
                    },
                }
            },
            .st_float, .st_double, .st_int8, .st_uint8, .st_int16, .st_uint16, .st_int32, .st_uint32, .st_int64, .st_uint64, .st_bool => {
                // st slot, index, value
                try c.address(a, b, pc);
                const off: u64 = code[pc + 1];
                switch (op) {
                    .st_float => {
                        try c.gf(cc);
                        try c.byte(W.f32_demote_f64);
                        try c.mem(W.f32_store, off);
                    },
                    .st_double => {
                        try c.gf(cc);
                        try c.mem(W.f64_store, off);
                    },
                    .st_bool => {
                        try c.gi(cc);
                        try c.i64c(0);
                        try c.byte(W.i64_ne);
                        try c.mem(W.i32_store8, off);
                    },
                    else => {
                        try c.gi(cc);
                        try c.mem(switch (op) {
                            .st_int8, .st_uint8 => W.i64_store8,
                            .st_int16, .st_uint16 => W.i64_store16,
                            .st_int32, .st_uint32 => W.i64_store32,
                            else => W.i64_store,
                        }, off);
                    },
                }
            },
        }
    }

    /// Finds the loops: a jump back to block h from block e makes the
    /// blocks h..e a loop (the farthest such e). They must nest, and every
    /// jump must go forward or back to the head of a loop it is in, as code
    /// made from for loops and ifs does; error.Unsupported otherwise.
    fn loops(c: *Compiler) Error!void {
        const code = c.p.code;
        const n = c.starts.items.len;
        c.loop_end = try c.gpa.alloc(u32, n);
        @memset(c.loop_end, NONE);
        c.forward = try c.gpa.alloc(bool, n);
        @memset(c.forward, false);
        var pc: u32 = 0;
        while (pc < code.len) {
            const op: Op = @enumFromInt(@as(u8, @truncate(code[pc])));
            if (vm.isJump(op)) {
                const from = c.block_of[pc];
                const to = c.block_of[code[pc + 1]];
                if (to <= from) {
                    if (c.loop_end[to] == NONE or c.loop_end[to] < from) c.loop_end[to] = from;
                } else c.forward[to] = true;
            }
            pc += if (vm.hasWord(op)) 2 else 1;
        }
        // nested, not overlapping
        var h: u32 = 0;
        while (h < n) : (h += 1) {
            const e = c.loop_end[h];
            if (e == NONE) continue;
            var k = h + 1;
            while (k <= e) : (k += 1) {
                if (c.loop_end[k] != NONE and c.loop_end[k] > e) return error.Unsupported;
            }
        }
    }

    /// The blocks s..e as one scope: a loop (or the function), the wasm
    /// blocks its forward jumps end, then its blocks and the loops in it.
    fn scope(c: *Compiler, s: u32, e: u32, is_loop: bool) Error!void {
        if (is_loop) {
            try c.byte(W.loop);
            try c.byte(T_VOID);
            try c.labels.append(c.gpa, .{ .loop = true, .at = s });
        }
        // the targets of jumps forward among this scope's own blocks (the
        // heads of the loops in it count; what is inside them does not)
        var targets: std.ArrayList(u32) = .empty;
        defer targets.deinit(c.gpa);
        var k = s;
        while (k <= e) {
            if (k != s and c.forward[k]) try targets.append(c.gpa, k);
            k = if (c.loop_end[k] != NONE and (k != s or !is_loop)) c.loop_end[k] + 1 else k + 1;
        }
        var i = targets.items.len;
        while (i > 0) {
            i -= 1;
            try c.byte(W.block);
            try c.byte(T_VOID);
            try c.labels.append(c.gpa, .{ .loop = false, .at = targets.items[i] });
        }
        k = s;
        while (k <= e) {
            if (k != s and c.forward[k]) {
                const top = c.labels.pop().?;
                std.debug.assert(!top.loop and top.at == k);
                try c.byte(W.end);
            }
            if (c.loop_end[k] != NONE and (k != s or !is_loop)) {
                try c.scope(k, c.loop_end[k], true);
                k = c.loop_end[k] + 1;
            } else {
                try c.blockCode(k);
                k += 1;
            }
        }
        if (is_loop) {
            _ = c.labels.pop();
            try c.byte(W.end);
        }
    }

    fn blockCode(c: *Compiler, k: u32) !void {
        const code = c.p.code;
        var pc = c.starts.items[k];
        const end: u32 = if (k + 1 < c.starts.items.len) c.starts.items[k + 1] else @intCast(code.len);
        while (pc < end) {
            try c.instruction(pc);
            const op: Op = @enumFromInt(@as(u8, @truncate(code[pc])));
            pc += if (vm.hasWord(op)) 2 else 1;
        }
    }

    /// The function's code in the structured layout: real loops, so the
    /// browser's compiler sees them; error.Unsupported for control flow
    /// that does not nest (then body() lays it out).
    fn structuredBody(c: *Compiler) Error!Buf {
        c.structured = true;
        try c.loops();
        var decl: Buf = .empty;
        errdefer decl.deinit(c.gpa);
        try c.locals(&decl);
        try c.prologue();
        try c.scope(0, @intCast(c.starts.items.len - 1), false);
        // (every program ends with a return)
        try c.byte(W.@"unreachable");
        try c.byte(W.end);
        try decl.appendSlice(c.gpa, c.b.items);
        return decl;
    }

    /// The function's code: locals, prologue, the blocks in their loop.
    fn body(c: *Compiler) !Buf {
        c.structured = false;
        const code = c.p.code;
        const n: u32 = @intCast(c.starts.items.len);
        var decl: Buf = .empty;
        errdefer decl.deinit(c.gpa);
        try c.locals(&decl);
        try c.prologue();
        // loop, then a block per basic block (the first innermost), the
        // dispatch on the label
        try c.byte(W.loop);
        try c.byte(T_VOID);
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            try c.byte(W.block);
            try c.byte(T_VOID);
        }
        try c.get(c.l_label);
        try c.byte(W.br_table);
        try c.u(n);
        k = 0;
        while (k < n) : (k += 1) try c.u(k);
        try c.u(0);
        var pc: u32 = 0;
        var block: u32 = 0;
        while (pc < code.len) {
            if (block < n and pc == c.starts.items[block]) {
                // the end of block `block`: its code follows
                try c.byte(W.end);
                block += 1;
            }
            try c.instruction(pc);
            const op: Op = @enumFromInt(@as(u8, @truncate(code[pc])));
            pc += if (vm.hasWord(op)) 2 else 1;
        }
        // (every program ends with a return)
        try c.byte(W.end);
        try c.byte(W.@"unreachable");
        try c.byte(W.end);
        try decl.appendSlice(c.gpa, c.b.items);
        return decl;
    }
};

fn section(gpa: Allocator, m: *Buf, id: u8, content: []const u8) !void {
    try m.append(gpa, id);
    try uleb(gpa, m, content.len);
    try m.appendSlice(gpa, content);
}

fn name(gpa: Allocator, b: *Buf, s: []const u8) !void {
    try uleb(gpa, b, s.len);
    try b.appendSlice(gpa, s);
}

/// Compiles a loaded (and validated) program. strides[slot] is the element
/// size of each array slot, known from the parameter kinds.
pub fn compile(gpa: Allocator, p: *const vm.Program, strides: *const [64]u32) Error!Code {
    var c = Compiler{ .gpa = gpa, .p = p, .stride = strides.* };
    defer c.deinit();
    try c.plan();
    var code = c.structuredBody() catch |e| switch (e) {
        error.Unsupported => blk: {
            c.b.clearRetainingCapacity();
            c.labels.clearRetainingCapacity();
            break :blk try c.body();
        },
        else => return e,
    };
    defer code.deinit(gpa);

    var m: Buf = .empty;
    defer m.deinit(gpa);
    var s: Buf = .empty;
    defer s.deinit(gpa);
    try m.appendSlice(gpa, &.{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 });
    // types: 0 run, 1 f64 -> f64, 2 (f64, f64) -> f64
    try uleb(gpa, &s, 3);
    try s.appendSlice(gpa, &.{ 0x60, 4, T_I32, T_I32, T_I32, T_I32, 1, T_I32 });
    try s.appendSlice(gpa, &.{ 0x60, 1, T_F64, 1, T_F64 });
    try s.appendSlice(gpa, &.{ 0x60, 2, T_F64, T_F64, 1, T_F64 });
    try section(gpa, &m, 1, s.items);
    // imports: the memory, the functions of libm by name (in the order
    // their indices were given)
    s.clearRetainingCapacity();
    try uleb(gpa, &s, 1 + c.math_count);
    try name(gpa, &s, "env");
    try name(gpa, &s, "memory");
    try s.appendSlice(gpa, &.{ 0x02, 0x00, 0x01 });
    var i: u32 = 0;
    while (i < c.math_count) : (i += 1) {
        for (c.math_index, 0..) |idx, f| {
            if (idx != i) continue;
            const which: Math = @enumFromInt(f);
            try name(gpa, &s, "env");
            try name(gpa, &s, @tagName(which));
            try s.append(gpa, 0x00);
            try uleb(gpa, &s, if (which == .pow or which == .atan2) 2 else 1);
        }
    }
    try section(gpa, &m, 2, s.items);
    // one function, of type 0, exported as run
    try section(gpa, &m, 3, &.{ 1, 0 });
    s.clearRetainingCapacity();
    try uleb(gpa, &s, 1);
    try name(gpa, &s, "run");
    try s.append(gpa, 0x00);
    try uleb(gpa, &s, c.math_count);
    try section(gpa, &m, 7, s.items);
    // its code
    s.clearRetainingCapacity();
    try uleb(gpa, &s, 1);
    try uleb(gpa, &s, code.items.len);
    try s.appendSlice(gpa, code.items);
    try section(gpa, &m, 10, s.items);

    if (std.c.getenv("SLANG_KERNEL_JIT")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "dump")) {
            std.debug.print("; kernel {s}: {d} bytes of wasm, {d} blocks, {s}\n", .{ p.name, m.items.len, c.starts.items.len, if (c.structured) "structured" else "dispatched" });
        }
    }
    const index = kernel_wasm_load(m.items.ptr, @intCast(m.items.len));
    if (index <= 0) return error.LoadFailed;
    return .{ .func = @ptrFromInt(@as(usize, @intCast(index))), .index = index };
}

pub fn free(code: *Code) void {
    kernel_wasm_free(code.index);
}
