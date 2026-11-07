//! The kernel JIT: kernel bytecode to arm64 machine code, one function per
//! program, with the same entry signature as the interpreter's exec.
//!
//! The design, in one paragraph. The bytecode machine has 256 int and 256
//! float registers that the interpreter keeps in two arrays in memory. The
//! compiled code keeps the arrays (they are the interface to the caller:
//! constants and arguments go in, the result comes out) and *pins* the most
//! used registers of each file to machine registers for the whole function:
//! six int registers to x23..x28 and eight float registers to d8..d15, all
//! callee-saved so that calls to libm leave them alone. Every other
//! bytecode register is loaded from its array slot before use and stored
//! back after, which is what the interpreter did anyway. Each bytecode
//! instruction becomes a short fixed sequence (a template); there is no
//! intermediate representation and no instruction scheduling. Bounds checks
//! branch to out-of-line stubs that fill the Outcome exactly as the
//! interpreter does, so faults report the same line.
//!
//! What the course builds, lesson by lesson, lives in this one file: the
//! register plan (pinning), the templates (emit*), labels and fixups for
//! branches, out-of-line fault stubs, calls into the runtime, and
//! executable memory (JitMemory).
const std = @import("std");
const builtin = @import("builtin");
const vm = @import("vm.zig");
const A = @import("arm64.zig");
const Reg = A.Reg;
const Op = vm.Op;

const Allocator = std.mem.Allocator;

/// The compiled entry: the interpreter's exec signature. Returns the
/// register that holds the result (0 for none) and fills out on a fault.
pub const Func = *const fn (I: *[256]i64, F: *[256]f64, slots: *const [64]vm.Slot, out: *vm.Outcome) callconv(.c) u8;

pub const Code = struct {
    mem: JitMemory,
    func: Func,
    words: usize,
};

pub const Error = error{ OutOfMemory, Unsupported, TooLarge, MapFailed };

/// Whether this build can JIT at all: arm64 on macOS or Linux.
pub const available = builtin.cpu.arch == .aarch64 and (builtin.os.tag == .macos or builtin.os.tag == .linux);

// ------------------------------------------------------------ the register plan

// Fixed roles. x0..x3 are the arguments on entry and then free; x9..x17
// and d0..d7 are scratch within one template (nothing survives a template
// in them); x16 is the call target.
const rI: Reg = 19; // *[256]i64
const rF: Reg = 20; // *[256]f64
const rSlots: Reg = 21; // *[64]Slot
const rOut: Reg = 22; // *Outcome
const pinned_int = [_]Reg{ 23, 24, 25, 26, 27, 28 };
const pinned_float = [_]Reg{ 8, 9, 10, 11, 12, 13, 14, 15 };
// scratch
const sB: Reg = 9; // int operand b
const sC: Reg = 10; // int operand c
const sD: Reg = 11; // int destination
const sIdx: Reg = 12; // an index (the fault stub reads it here)
const sLen: Reg = 13; // a length (the fault stub reads it here)
const sAddr: Reg = 14; // an element address
const sT: Reg = 15; // misc
const sCall: Reg = 16; // the address of a called function
const sT2: Reg = 17; // misc
const fB: Reg = 0; // float operand b (also the first call argument)
const fC: Reg = 1; // float operand c (also the second)
const fD: Reg = 2; // float destination
const fT: Reg = 3;
const fT2: Reg = 4;

// The frame: [sp] x29 x30, then the callee-saved registers this code uses.
const frame_size = 160;

/// Where a bytecode register lives: a machine register, or its array slot.
const Home = union(enum) { reg: Reg, mem };

const Fixup = struct {
    at: u32, // the word to patch
    label: u32,
    kind: enum { b, imm19 }, // b (imm26) or b.cond/cbz/cbnz (imm19)
};

const Stub = struct {
    label: u32,
    kind: enum { index, divide },
    pc: u32,
    idx: Reg, // index kind: where the index is
};

const Compiler = struct {
    gpa: Allocator,
    p: *const vm.Program,
    code: std.ArrayList(u32) = .empty,
    labels: std.ArrayList(u32) = .empty, // label -> word offset (max = unbound)
    fixups: std.ArrayList(Fixup) = .empty,
    stubs: std.ArrayList(Stub) = .empty,
    pc_label: []u32, // bytecode pc -> label
    home_i: [256]Home,
    home_f: [256]Home,
    stride: [64]u32,
    l_epilogue: u32,
    l_fault_index: u32,
    l_fault_divide: u32,

    const unbound = std.math.maxInt(u32);

    fn deinit(self: *Compiler) void {
        self.code.deinit(self.gpa);
        self.labels.deinit(self.gpa);
        self.fixups.deinit(self.gpa);
        self.stubs.deinit(self.gpa);
        self.gpa.free(self.pc_label);
    }

    // ---- words, labels, fixups

    fn emit(self: *Compiler, w: u32) Error!void {
        try self.code.append(self.gpa, w);
    }

    fn newLabel(self: *Compiler) Error!u32 {
        try self.labels.append(self.gpa, unbound);
        return @intCast(self.labels.items.len - 1);
    }

    fn bind(self: *Compiler, label: u32) void {
        self.labels.items[label] = @intCast(self.code.items.len);
    }

    /// b label
    fn jump(self: *Compiler, label: u32) Error!void {
        try self.fixups.append(self.gpa, .{ .at = @intCast(self.code.items.len), .label = label, .kind = .b });
        try self.emit(A.b(0));
    }
    /// b.cond label
    fn jumpIf(self: *Compiler, c: A.Cond, label: u32) Error!void {
        try self.fixups.append(self.gpa, .{ .at = @intCast(self.code.items.len), .label = label, .kind = .imm19 });
        try self.emit(A.bcond(c, 0));
    }
    /// cbz / cbnz reg, label
    fn jumpZero(self: *Compiler, reg: Reg, zero: bool, label: u32) Error!void {
        try self.fixups.append(self.gpa, .{ .at = @intCast(self.code.items.len), .label = label, .kind = .imm19 });
        try self.emit(if (zero) A.cbz(reg, 0) else A.cbnz(reg, 0));
    }

    fn patch(self: *Compiler) Error!void {
        for (self.fixups.items) |f| {
            const target = self.labels.items[f.label];
            if (target == unbound) return error.Unsupported;
            const off: i64 = @as(i64, target) - @as(i64, f.at);
            switch (f.kind) {
                .b => {
                    if (off < -(1 << 25) or off >= (1 << 25)) return error.TooLarge;
                    self.code.items[f.at] |= @as(u32, @as(u26, @bitCast(@as(i26, @intCast(off)))));
                },
                .imm19 => {
                    if (off < -(1 << 18) or off >= (1 << 18)) return error.TooLarge;
                    self.code.items[f.at] |= @as(u32, @as(u19, @bitCast(@as(i19, @intCast(off))))) << 5;
                },
            }
        }
    }

    // ---- operands

    /// The machine register holding int register vr, loading it into
    /// scratch when it lives in memory.
    fn srcI(self: *Compiler, vr: u8, scratch: Reg) Error!Reg {
        switch (self.home_i[vr]) {
            .reg => |m| return m,
            .mem => {
                try self.emit(A.ldrX(scratch, rI, vr));
                return scratch;
            },
        }
    }
    /// The register a result for int register vr goes into.
    fn dstI(self: *Compiler, vr: u8, scratch: Reg) Reg {
        return switch (self.home_i[vr]) {
            .reg => |m| m,
            .mem => scratch,
        };
    }
    /// After the result for vr was computed into reg (dstI's answer).
    fn commitI(self: *Compiler, vr: u8, reg: Reg) Error!void {
        switch (self.home_i[vr]) {
            .reg => |m| if (m != reg) try self.emit(A.mov(m, reg)),
            .mem => try self.emit(A.strX(reg, rI, vr)),
        }
    }
    fn srcF(self: *Compiler, vr: u8, scratch: Reg) Error!Reg {
        switch (self.home_f[vr]) {
            .reg => |m| return m,
            .mem => {
                try self.emit(A.ldrD(scratch, rF, vr));
                return scratch;
            },
        }
    }
    fn dstF(self: *Compiler, vr: u8, scratch: Reg) Reg {
        return switch (self.home_f[vr]) {
            .reg => |m| m,
            .mem => scratch,
        };
    }
    fn commitF(self: *Compiler, vr: u8, reg: Reg) Error!void {
        switch (self.home_f[vr]) {
            .reg => |m| if (m != reg) try self.emit(A.fmov(m, reg)),
            .mem => try self.emit(A.strD(reg, rF, vr)),
        }
    }

    fn movImm(self: *Compiler, reg: Reg, value: u64) Error!void {
        var buf: [4]u32 = undefined;
        const n = A.movImm64(&buf, reg, value);
        for (buf[0..n]) |w| try self.emit(w);
    }

    // ---- calls into the runtime

    /// x0 = f(x0, x1) with the C ABI; the address is loaded into x16.
    fn call(self: *Compiler, f: anytype) Error!void {
        try self.movImm(sCall, @intFromPtr(f));
        try self.emit(A.blr(sCall));
    }

    /// F[a] = f(F[b])
    fn callF1(self: *Compiler, a: u8, b: u8, f: *const fn (f64) callconv(.c) f64) Error!void {
        const rb = try self.srcF(b, fB);
        if (rb != fB) try self.emit(A.fmov(fB, rb));
        try self.call(f);
        try self.commitF(a, fB);
    }
    /// F[a] = f(F[b], F[c])
    fn callF2(self: *Compiler, a: u8, b: u8, c: u8, f: *const fn (f64, f64) callconv(.c) f64) Error!void {
        const rb = try self.srcF(b, fB);
        const rc = try self.srcF(c, fC);
        // both into d0/d1 without one overwriting the other
        if (rb == fC and rc == fB) {
            try self.emit(A.fmov(fT, rb));
            try self.emit(A.fmov(fC, rc));
            try self.emit(A.fmov(fB, fT));
        } else {
            if (rc != fC) try self.emit(A.fmov(fC, rc));
            if (rb != fB) try self.emit(A.fmov(fB, rb));
        }
        try self.call(f);
        try self.commitF(a, fB);
    }
    /// I[a] = f(I[b], I[c])
    fn callI2(self: *Compiler, a: u8, b: u8, c: u8, f: *const fn (i64, i64) callconv(.c) i64) Error!void {
        const rb = try self.srcI(b, 0);
        const rc = try self.srcI(c, 1);
        if (rb == 1 and rc == 0) {
            try self.emit(A.mov(sT, rb));
            try self.emit(A.mov(1, rc));
            try self.emit(A.mov(0, sT));
        } else {
            if (rc != 1) try self.emit(A.mov(1, rc));
            if (rb != 0) try self.emit(A.mov(0, rb));
        }
        try self.call(f);
        try self.commitI(a, 0);
    }

    // ---- the templates

    fn int3(self: *Compiler, w: u32, comptime make: fn (Reg, Reg, Reg) u32) Error!void {
        const rb = try self.srcI(vm.rb(w), sB);
        const rc = try self.srcI(vm.rc(w), sC);
        const rd = self.dstI(vm.ra(w), sD);
        try self.emit(make(rd, rb, rc));
        try self.commitI(vm.ra(w), rd);
    }
    fn int2(self: *Compiler, w: u32, comptime make: fn (Reg, Reg) u32) Error!void {
        const rb = try self.srcI(vm.rb(w), sB);
        const rd = self.dstI(vm.ra(w), sD);
        try self.emit(make(rd, rb));
        try self.commitI(vm.ra(w), rd);
    }
    fn float3(self: *Compiler, w: u32, comptime make: fn (Reg, Reg, Reg) u32) Error!void {
        const rb = try self.srcF(vm.rb(w), fB);
        const rc = try self.srcF(vm.rc(w), fC);
        const rd = self.dstF(vm.ra(w), fD);
        try self.emit(make(rd, rb, rc));
        try self.commitF(vm.ra(w), rd);
    }
    fn float2(self: *Compiler, w: u32, comptime make: fn (Reg, Reg) u32) Error!void {
        const rb = try self.srcF(vm.rb(w), fB);
        const rd = self.dstF(vm.ra(w), fD);
        try self.emit(make(rd, rb));
        try self.commitF(vm.ra(w), rd);
    }
    /// I[a] = I[b] cmp I[c]
    fn cmpI(self: *Compiler, w: u32, c: A.Cond) Error!void {
        const rb = try self.srcI(vm.rb(w), sB);
        const rc = try self.srcI(vm.rc(w), sC);
        const rd = self.dstI(vm.ra(w), sD);
        try self.emit(A.cmp(rb, rc));
        try self.emit(A.cset(rd, c));
        try self.commitI(vm.ra(w), rd);
    }
    /// I[a] = F[b] cmp F[c]
    fn cmpF(self: *Compiler, w: u32, c: A.Cond) Error!void {
        const rb = try self.srcF(vm.rb(w), fB);
        const rc = try self.srcF(vm.rc(w), fC);
        const rd = self.dstI(vm.ra(w), sD);
        try self.emit(A.fcmp(rb, rc));
        try self.emit(A.cset(rd, c));
        try self.commitI(vm.ra(w), rd);
    }
    /// if (I[a] cmp I[b]) goto target
    fn jumpCmpI(self: *Compiler, w: u32, c: A.Cond, target: u32) Error!void {
        const ra = try self.srcI(vm.ra(w), sB);
        const rb = try self.srcI(vm.rb(w), sC);
        try self.emit(A.cmp(ra, rb));
        try self.jumpIf(c, self.pc_label[target]);
    }
    fn jumpCmpF(self: *Compiler, w: u32, c: A.Cond, target: u32) Error!void {
        const ra = try self.srcF(vm.ra(w), fB);
        const rb = try self.srcF(vm.rb(w), fC);
        try self.emit(A.fcmp(ra, rb));
        try self.jumpIf(c, self.pc_label[target]);
    }

    /// The address of element I[idx_vr] of slot, plus off, into sAddr,
    /// after the bounds check (which branches to a fault stub).
    fn elementAddr(self: *Compiler, slot: u8, idx_vr: u8, off: u32, pc: u32) Error!void {
        const base_word: u12 = @intCast(slot * 3); // Slot is 24 bytes: base, len, stride
        try self.emit(A.ldrX(sLen, rSlots, base_word + 1));
        const idx = try self.srcI(idx_vr, sIdx);
        try self.emit(A.cmp(idx, sLen));
        const stub = try self.newLabel();
        try self.stubs.append(self.gpa, .{ .label = stub, .kind = .index, .pc = pc, .idx = idx });
        try self.jumpIf(.hs, stub);
        try self.emit(A.ldrX(sAddr, rSlots, base_word));
        const stride = self.stride[slot];
        if (stride == 1) {
            try self.emit(A.add(sAddr, sAddr, idx));
        } else if (std.math.isPowerOfTwo(stride)) {
            try self.emit(A.addShifted(sAddr, sAddr, idx, @intCast(std.math.log2_int(u32, stride))));
        } else {
            try self.movImm(sT, stride);
            try self.emit(A.madd(sAddr, idx, sT, sAddr));
        }
        if (off != 0) {
            if (off >= 4096) return error.Unsupported;
            try self.emit(A.addImm(sAddr, sAddr, @intCast(off)));
        }
    }

    fn load(self: *Compiler, op: Op, w: u32, off: u32, pc: u32) Error!void {
        try self.elementAddr(vm.rb(w), vm.rc(w), off, pc);
        const a = vm.ra(w);
        switch (op) {
            .ld_float => {
                const rd = self.dstF(a, fD);
                try self.emit(A.ldrS(fT, sAddr, 0));
                try self.emit(A.fcvtDS(rd, fT));
                try self.commitF(a, rd);
            },
            .ld_double => {
                const rd = self.dstF(a, fD);
                try self.emit(A.ldrD(rd, sAddr, 0));
                try self.commitF(a, rd);
            },
            else => {
                const rd = self.dstI(a, sD);
                try self.emit(switch (op) {
                    .ld_int8 => A.ldrsb(rd, sAddr, 0),
                    .ld_uint8, .ld_bool => A.ldrb(rd, sAddr, 0),
                    .ld_int16 => A.ldrsh(rd, sAddr, 0),
                    .ld_uint16 => A.ldrh(rd, sAddr, 0),
                    .ld_int32 => A.ldrsw(rd, sAddr, 0),
                    .ld_uint32 => A.ldrW(rd, sAddr, 0),
                    .ld_int64, .ld_uint64 => A.ldrX(rd, sAddr, 0),
                    else => unreachable,
                });
                if (op == .ld_bool) {
                    try self.emit(A.cmpImm(rd, 0));
                    try self.emit(A.cset(rd, .ne));
                }
                try self.commitI(a, rd);
            },
        }
    }

    fn store(self: *Compiler, op: Op, w: u32, off: u32, pc: u32) Error!void {
        // st slot=a, index=b, value=c
        try self.elementAddr(vm.ra(w), vm.rb(w), off, pc);
        const v = vm.rc(w);
        switch (op) {
            .st_float => {
                const rv = try self.srcF(v, fB);
                try self.emit(A.fcvtSD(fT, rv));
                try self.emit(A.strS(fT, sAddr, 0));
            },
            .st_double => {
                const rv = try self.srcF(v, fB);
                try self.emit(A.strD(rv, sAddr, 0));
            },
            .st_bool => {
                const rv = try self.srcI(v, sB);
                try self.emit(A.cmpImm(rv, 0));
                try self.emit(A.cset(sT, .ne));
                try self.emit(A.strb(sT, sAddr, 0));
            },
            else => {
                const rv = try self.srcI(v, sB);
                try self.emit(switch (op) {
                    .st_int8, .st_uint8 => A.strb(rv, sAddr, 0),
                    .st_int16, .st_uint16 => A.strh(rv, sAddr, 0),
                    .st_int32, .st_uint32 => A.strW(rv, sAddr, 0),
                    .st_int64, .st_uint64 => A.strX(rv, sAddr, 0),
                    else => unreachable,
                });
            },
        }
    }

    fn instruction(self: *Compiler, pc: u32) Error!void {
        const code = self.p.code;
        const w = code[pc];
        const op: Op = @enumFromInt(@as(u8, @truncate(w)));
        const a = vm.ra(w);
        const b = vm.rb(w);
        const c = vm.rc(w);
        const x: u32 = if (vm.hasWord(op)) code[pc + 1] else 0;
        switch (op) {
            .nop => {},
            .movi => {
                const rb = try self.srcI(b, sB);
                try self.commitI(a, rb);
            },
            .movf => {
                const rb = try self.srcF(b, fB);
                try self.commitF(a, rb);
            },
            .addi => try self.int3(w, A.add),
            .subi => try self.int3(w, A.sub),
            .muli => try self.int3(w, A.mul),
            .divi, .modi => {
                const rc = try self.srcI(c, sC);
                const stub = try self.newLabel();
                try self.stubs.append(self.gpa, .{ .label = stub, .kind = .divide, .pc = pc, .idx = 0 });
                try self.jumpZero(rc, true, stub);
                try self.callI2(a, b, c, if (op == .divi) &floorDiv else &floorMod);
            },
            .negi => try self.int2(w, A.neg),
            .andi => try self.int3(w, A.and_),
            .ori => try self.int3(w, A.orr),
            .xori => try self.int3(w, A.eor),
            .shli => try self.int3(w, A.lslv),
            .shri => try self.int3(w, A.asrv),
            .noti => try self.int2(w, A.mvn),
            .addf => try self.float3(w, A.fadd),
            .subf => try self.float3(w, A.fsub),
            .mulf => try self.float3(w, A.fmul),
            .divf => try self.float3(w, A.fdiv),
            .modf => {
                // x - y * floor(x / y), rounded at each step as the interpreter does
                const rx = try self.srcF(b, fB);
                const ry = try self.srcF(c, fC);
                const rd = self.dstF(a, fD);
                try self.emit(A.fdiv(fT, rx, ry));
                try self.emit(A.frintm(fT, fT));
                try self.emit(A.fmul(fT, ry, fT));
                try self.emit(A.fsub(rd, rx, fT));
                try self.commitF(a, rd);
            },
            .negf => try self.float2(w, A.fneg),
            .powf => try self.callF2(a, b, c, &pow),
            .madf => {
                // a = b + c * d, two roundings like the interpreter (fmadd would fuse them)
                const rb = try self.srcF(b, fB);
                const rc = try self.srcF(c, fC);
                const rd4 = try self.srcF(@truncate(x), fT);
                const rd = self.dstF(a, fD);
                try self.emit(A.fmul(fT2, rc, rd4));
                try self.emit(A.fadd(rd, rb, fT2));
                try self.commitF(a, rd);
            },
            .itof => {
                const rb = try self.srcI(b, sB);
                const rd = self.dstF(a, fD);
                try self.emit(A.scvtf(rd, rb));
                try self.commitF(a, rd);
            },
            .ftoi => {
                // fcvtzs truncates, saturates and makes NaN 0: toInt exactly
                const rb = try self.srcF(b, fB);
                const rd = self.dstI(a, sD);
                try self.emit(A.fcvtzs(rd, rb));
                try self.commitI(a, rd);
            },
            .lti => try self.cmpI(w, .lt),
            .lei => try self.cmpI(w, .le),
            .eqi => try self.cmpI(w, .eq),
            .nei => try self.cmpI(w, .ne),
            .ltf => try self.cmpF(w, .mi),
            .lef => try self.cmpF(w, .ls),
            .eqf => try self.cmpF(w, .eq),
            .nef => try self.cmpF(w, .ne),
            .notb => {
                const rb = try self.srcI(b, sB);
                const rd = self.dstI(a, sD);
                try self.emit(A.cmpImm(rb, 0));
                try self.emit(A.cset(rd, .eq));
                try self.commitI(a, rd);
            },
            .jmp => try self.jump(self.pc_label[x]),
            .jt, .jf => {
                const ra = try self.srcI(a, sB);
                try self.jumpZero(ra, op == .jf, self.pc_label[x]);
            },
            .jlti => try self.jumpCmpI(w, .lt, x),
            .jlei => try self.jumpCmpI(w, .le, x),
            .jeqi => try self.jumpCmpI(w, .eq, x),
            .jnei => try self.jumpCmpI(w, .ne, x),
            .jltf => try self.jumpCmpF(w, .mi, x),
            .jlef => try self.jumpCmpF(w, .ls, x),
            .jeqf => try self.jumpCmpF(w, .eq, x),
            .jnef => try self.jumpCmpF(w, .ne, x),
            .jnltf => try self.jumpCmpF(w, .pl, x),
            .jnlef => try self.jumpCmpF(w, .hi, x),
            .seli => {
                const cond = try self.srcI(@truncate(x), sT);
                const rb = try self.srcI(b, sB);
                const rc = try self.srcI(c, sC);
                const rd = self.dstI(a, sD);
                try self.emit(A.cmpImm(cond, 0));
                try self.emit(A.csel(rd, rb, rc, .ne));
                try self.commitI(a, rd);
            },
            .self => {
                const cond = try self.srcI(@truncate(x), sT);
                const rb = try self.srcF(b, fB);
                const rc = try self.srcF(c, fC);
                const rd = self.dstF(a, fD);
                try self.emit(A.cmpImm(cond, 0));
                try self.emit(A.fcsel(rd, rb, rc, .ne));
                try self.commitF(a, rd);
            },
            .len => {
                const rd = self.dstI(a, sD);
                try self.emit(A.ldrX(rd, rSlots, @intCast(b * 3 + 1)));
                try self.commitI(a, rd);
            },
            .sin => try self.callF1(a, b, &sin),
            .cos => try self.callF1(a, b, &cos),
            .tan => try self.callF1(a, b, &tan),
            .asin => try self.callF1(a, b, &asin),
            .acos => try self.callF1(a, b, &acos),
            .atan => try self.callF1(a, b, &atan),
            .exp => try self.callF1(a, b, &exp),
            .exp2 => try self.callF1(a, b, &exp2),
            .log => try self.callF1(a, b, &log),
            .log2 => try self.callF1(a, b, &log2),
            .tanh => try self.callF1(a, b, &tanh),
            .sinh => try self.callF1(a, b, &sinh),
            .cosh => try self.callF1(a, b, &cosh),
            .atan2 => try self.callF2(a, b, c, &atan2),
            .sqrt => try self.float2(w, A.fsqrt),
            .absf => try self.float2(w, A.fabs),
            .floor => try self.float2(w, A.frintm),
            .ceil => try self.float2(w, A.frintp),
            .round => try self.float2(w, A.frinta),
            .trunc => try self.float2(w, A.frintz),
            .fract => {
                const rb = try self.srcF(b, fB);
                const rd = self.dstF(a, fD);
                try self.emit(A.frintm(fT, rb));
                try self.emit(A.fsub(rd, rb, fT));
                try self.commitF(a, rd);
            },
            .signf => {
                // x > 0 ? 1 : x < 0 ? -1 : x (NaN and signed zeros stay)
                const rb = try self.srcF(b, fB);
                const rd = self.dstF(a, fD);
                try self.emit(A.fcmpZero(rb));
                try self.emit(A.fmovOne(fT));
                try self.emit(A.fmovMinusOne(fT2));
                try self.emit(A.fcsel(rd, fT, rb, .gt));
                try self.emit(A.fcsel(rd, fT2, rd, .mi));
                try self.commitF(a, rd);
            },
            .minf, .maxf => {
                // y < x ? y : x (maxf: y > x), so a NaN x stays, as the interpreter has it
                const rx = try self.srcF(b, fB);
                const ry = try self.srcF(c, fC);
                const rd = self.dstF(a, fD);
                try self.emit(A.fcmp(ry, rx));
                try self.emit(A.fcsel(rd, ry, rx, if (op == .minf) .mi else .gt));
                try self.commitF(a, rd);
            },
            .mini, .maxi => {
                const rb = try self.srcI(b, sB);
                const rc = try self.srcI(c, sC);
                const rd = self.dstI(a, sD);
                try self.emit(A.cmp(rb, rc));
                try self.emit(A.csel(rd, rb, rc, if (op == .mini) .lt else .gt));
                try self.commitI(a, rd);
            },
            .absi => {
                const rb = try self.srcI(b, sB);
                const rd = self.dstI(a, sD);
                try self.emit(A.cmpImm(rb, 0));
                try self.emit(A.cneg(rd, rb, .lt));
                try self.commitI(a, rd);
            },
            .signi => {
                const rb = try self.srcI(b, sB);
                const rd = self.dstI(a, sD);
                try self.emit(A.cmpImm(rb, 0));
                try self.emit(A.cset(sT, .gt));
                try self.emit(A.cset(sT2, .lt));
                try self.emit(A.sub(rd, sT, sT2));
                try self.commitI(a, rd);
            },
            .ret => {
                try self.emit(A.movz(0, 0, 0));
                try self.jump(self.l_epilogue);
            },
            .reti, .retf => {
                try self.emit(A.movz(0, a, 0));
                try self.jump(self.l_epilogue);
            },
            .ld_float, .ld_double, .ld_int8, .ld_uint8, .ld_int16, .ld_uint16, .ld_int32, .ld_uint32, .ld_int64, .ld_uint64, .ld_bool => try self.load(op, w, x, pc),
            .st_float, .st_double, .st_int8, .st_uint8, .st_int16, .st_uint16, .st_int32, .st_uint32, .st_int64, .st_uint64, .st_bool => try self.store(op, w, x, pc),
            .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei => {
                // I[a] += I[b]; jump while I[a] compares to I[c]
                const ra = try self.srcI(a, sB);
                const rb = try self.srcI(b, sC);
                const rd = self.dstI(a, sD);
                try self.emit(A.add(rd, ra, rb));
                try self.commitI(a, rd);
                const rc = try self.srcI(c, sC);
                try self.emit(A.cmp(rd, rc));
                try self.jumpIf(switch (op) {
                    .addi_jlti => .lt,
                    .addi_jlei => .le,
                    .addi_jgti => .gt,
                    .addi_jgei => .ge,
                    else => unreachable,
                }, self.pc_label[x]);
            },
        }
    }

    // ---- prologue, epilogue, stubs

    fn prologue(self: *Compiler) Error!void {
        try self.emit(A.subImm(A.sp, A.sp, frame_size));
        try self.emit(A.stpX(A.fp, A.lr, A.sp, 0));
        try self.emit(A.stpX(19, 20, A.sp, 2));
        try self.emit(A.stpX(21, 22, A.sp, 4));
        try self.emit(A.stpX(23, 24, A.sp, 6));
        try self.emit(A.stpX(25, 26, A.sp, 8));
        try self.emit(A.stpX(27, 28, A.sp, 10));
        try self.emit(A.stpD(8, 9, A.sp, 12));
        try self.emit(A.stpD(10, 11, A.sp, 14));
        try self.emit(A.stpD(12, 13, A.sp, 16));
        try self.emit(A.stpD(14, 15, A.sp, 18));
        try self.emit(A.movFpSp);
        try self.emit(A.mov(rI, 0));
        try self.emit(A.mov(rF, 1));
        try self.emit(A.mov(rSlots, 2));
        try self.emit(A.mov(rOut, 3));
        // the pinned registers start with what the arrays hold (constants, arguments)
        for (self.home_i, 0..) |h, vr| {
            if (h == .reg) try self.emit(A.ldrX(h.reg, rI, @intCast(vr)));
        }
        for (self.home_f, 0..) |h, vr| {
            if (h == .reg) try self.emit(A.ldrD(h.reg, rF, @intCast(vr)));
        }
    }

    fn epilogue(self: *Compiler) Error!void {
        self.bind(self.l_epilogue);
        // the arrays get the pinned registers back (the caller reads the result there)
        for (self.home_i, 0..) |h, vr| {
            if (h == .reg) try self.emit(A.strX(h.reg, rI, @intCast(vr)));
        }
        for (self.home_f, 0..) |h, vr| {
            if (h == .reg) try self.emit(A.strD(h.reg, rF, @intCast(vr)));
        }
        try self.emit(A.ldpX(A.fp, A.lr, A.sp, 0));
        try self.emit(A.ldpX(19, 20, A.sp, 2));
        try self.emit(A.ldpX(21, 22, A.sp, 4));
        try self.emit(A.ldpX(23, 24, A.sp, 6));
        try self.emit(A.ldpX(25, 26, A.sp, 8));
        try self.emit(A.ldpX(27, 28, A.sp, 10));
        try self.emit(A.ldpD(8, 9, A.sp, 12));
        try self.emit(A.ldpD(10, 11, A.sp, 14));
        try self.emit(A.ldpD(12, 13, A.sp, 16));
        try self.emit(A.ldpD(14, 15, A.sp, 18));
        try self.emit(A.addImm(A.sp, A.sp, frame_size));
        try self.emit(A.ret);
    }

    /// The shared fault tails and the per-site stubs that feed them.
    fn faults(self: *Compiler) Error!void {
        const pc_off = @offsetOf(vm.Outcome, "pc");
        const fault_off = @offsetOf(vm.Outcome, "fault");
        const index_off = @offsetOf(vm.Outcome, "index");
        const len_off = @offsetOf(vm.Outcome, "len");
        // index: x12 index, x13 length, w14 pc
        self.bind(self.l_fault_index);
        try self.emit(A.strW(sT2, rOut, pc_off / 4));
        try self.emit(A.strX(sIdx, rOut, index_off / 8));
        try self.emit(A.strX(sLen, rOut, len_off / 8));
        try self.emit(A.movz(sT, @intFromEnum(vm.Fault.index), 0));
        try self.emit(A.strb(sT, rOut, fault_off));
        try self.emit(A.movz(0, 0, 0));
        try self.jump(self.l_epilogue);
        // divide: w14 pc
        self.bind(self.l_fault_divide);
        try self.emit(A.strW(sT2, rOut, pc_off / 4));
        try self.emit(A.movz(sT, @intFromEnum(vm.Fault.divide), 0));
        try self.emit(A.strb(sT, rOut, fault_off));
        try self.emit(A.movz(0, 0, 0));
        try self.jump(self.l_epilogue);
        for (self.stubs.items) |s| {
            self.bind(s.label);
            try self.movImm(sT2, s.pc);
            switch (s.kind) {
                .index => {
                    if (s.idx != sIdx) try self.emit(A.mov(sIdx, s.idx));
                    try self.jump(self.l_fault_index);
                },
                .divide => try self.jump(self.l_fault_divide),
            }
        }
    }

    // ---- the register plan

    /// Which bytecode registers get machine registers: the most referenced,
    /// references inside loops weighing more.
    fn plan(self: *Compiler) void {
        const code = self.p.code;
        // loop depth per pc from backward jumps
        const depth = self.gpa.alloc(u8, code.len) catch return;
        defer self.gpa.free(depth);
        @memset(depth, 0);
        var pc: u32 = 0;
        while (pc < code.len) {
            const op: Op = @enumFromInt(@as(u8, @truncate(code[pc])));
            if (vm.isJump(op)) {
                const target = code[pc + 1];
                if (target <= pc) {
                    for (depth[target .. pc + 1]) |*d| d.* +|= 1;
                }
            }
            pc += if (vm.hasWord(op)) 2 else 1;
        }
        var wi: [256]u64 = @splat(0);
        var wf: [256]u64 = @splat(0);
        pc = 0;
        while (pc < code.len) {
            const w = code[pc];
            const op: Op = @enumFromInt(@as(u8, @truncate(w)));
            const weight: u64 = @as(u64, 1) << @intCast(@min(3 * @as(u32, depth[pc]), 30));
            const a = vm.ra(w);
            const b = vm.rb(w);
            const c = vm.rc(w);
            const x: u8 = if (vm.hasWord(op)) @truncate(code[pc + 1]) else 0;
            switch (op) {
                .nop, .jmp, .ret => {},
                .movi, .negi, .noti, .absi, .signi, .notb => {
                    wi[a] += weight;
                    wi[b] += weight;
                },
                .addi, .subi, .muli, .divi, .modi, .andi, .ori, .xori, .shli, .shri, .mini, .maxi, .lti, .lei, .eqi, .nei => {
                    wi[a] += weight;
                    wi[b] += weight;
                    wi[c] += weight;
                },
                .movf, .negf, .itof, .sin, .cos, .tan, .asin, .acos, .atan, .exp, .exp2, .log, .log2, .sqrt, .absf, .floor, .ceil, .round, .trunc, .fract, .tanh, .sinh, .cosh, .signf => {
                    wf[a] += weight;
                    wf[b] += weight;
                },
                .addf, .subf, .mulf, .divf, .modf, .powf, .atan2, .minf, .maxf => {
                    wf[a] += weight;
                    wf[b] += weight;
                    wf[c] += weight;
                },
                .madf => {
                    wf[a] += weight;
                    wf[b] += weight;
                    wf[c] += weight;
                    wf[x] += weight;
                },
                .ftoi => {
                    wi[a] += weight;
                    wf[b] += weight;
                },
                .ltf, .lef, .eqf, .nef => {
                    wi[a] += weight;
                    wf[b] += weight;
                    wf[c] += weight;
                },
                .jt, .jf, .reti => wi[a] += weight,
                .retf => wf[a] += weight,
                .jlti, .jlei, .jeqi, .jnei => {
                    wi[a] += weight;
                    wi[b] += weight;
                },
                .jltf, .jlef, .jeqf, .jnef, .jnltf, .jnlef => {
                    wf[a] += weight;
                    wf[b] += weight;
                },
                .seli => {
                    wi[a] += weight;
                    wi[b] += weight;
                    wi[c] += weight;
                    wi[x] += weight;
                },
                .self => {
                    wf[a] += weight;
                    wf[b] += weight;
                    wf[c] += weight;
                    wi[x] += weight;
                },
                .len => wi[a] += weight,
                .ld_float, .ld_double => {
                    wf[a] += weight;
                    wi[c] += weight;
                },
                .ld_int8, .ld_uint8, .ld_int16, .ld_uint16, .ld_int32, .ld_uint32, .ld_int64, .ld_uint64, .ld_bool => {
                    wi[a] += weight;
                    wi[c] += weight;
                },
                .st_float, .st_double => {
                    wi[b] += weight;
                    wf[c] += weight;
                },
                .st_int8, .st_uint8, .st_int16, .st_uint16, .st_int32, .st_uint32, .st_int64, .st_uint64, .st_bool => {
                    wi[b] += weight;
                    wi[c] += weight;
                },
                .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei => {
                    wi[a] += 2 * weight;
                    wi[b] += weight;
                    wi[c] += weight;
                },
            }
            pc += if (vm.hasWord(op)) 2 else 1;
        }
        pickHomes(&self.home_i, &wi, &pinned_int);
        pickHomes(&self.home_f, &wf, &pinned_float);
    }

    fn pickHomes(homes: *[256]Home, weights: *[256]u64, machine: []const Reg) void {
        @memset(homes, .mem);
        for (machine) |m| {
            var best: usize = 0;
            var best_w: u64 = 0;
            for (weights, 0..) |w, vr| {
                if (w > best_w) {
                    best_w = w;
                    best = vr;
                }
            }
            if (best_w == 0) break;
            homes[best] = .{ .reg = m };
            weights[best] = 0;
        }
    }
};

// ------------------------------------------------------------ the runtime the code calls

// libm, the functions the interpreter also calls (LLVM lowers @sin and
// friends to these), so that results are bit-identical
extern fn sin(x: f64) callconv(.c) f64;
extern fn cos(x: f64) callconv(.c) f64;
extern fn tan(x: f64) callconv(.c) f64;
extern fn asin(x: f64) callconv(.c) f64;
extern fn acos(x: f64) callconv(.c) f64;
extern fn atan(x: f64) callconv(.c) f64;
extern fn exp(x: f64) callconv(.c) f64;
extern fn exp2(x: f64) callconv(.c) f64;
extern fn log(x: f64) callconv(.c) f64;
extern fn log2(x: f64) callconv(.c) f64;
extern fn tanh(x: f64) callconv(.c) f64;
extern fn sinh(x: f64) callconv(.c) f64;
extern fn cosh(x: f64) callconv(.c) f64;
extern fn atan2(y: f64, x: f64) callconv(.c) f64;
extern fn pow(x: f64, y: f64) callconv(.c) f64;

fn floorDiv(x: i64, y: i64) callconv(.c) i64 {
    return vm.floorDiv(x, y);
}
fn floorMod(x: i64, y: i64) callconv(.c) i64 {
    return vm.floorMod(x, y);
}

// ------------------------------------------------------------ executable memory

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
extern fn __clear_cache(start: *anyopaque, end: *anyopaque) void;

/// A page-aligned mapping that holds machine code. On macOS the pages are
/// readable, writable and executable at once (MAP_JIT) and a per-thread
/// switch says which of writing and executing is allowed right now; on
/// Linux the pages are made executable after the code is written.
pub const JitMemory = struct {
    bytes: []align(std.heap.page_size_min) u8,

    pub fn map(len: usize) Error!JitMemory {
        const size = std.mem.alignForward(usize, len, std.heap.page_size_min);
        const prot: std.posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = builtin.os.tag == .macos };
        var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        if (builtin.os.tag == .macos) flags.JIT = true;
        const bytes = std.posix.mmap(null, size, prot, flags, -1, 0) catch return error.MapFailed;
        return .{ .bytes = bytes };
    }

    /// Copies the code in and makes it executable.
    pub fn write(self: *JitMemory, code: []const u32) Error!void {
        const src = std.mem.sliceAsBytes(code);
        if (builtin.os.tag == .macos) pthread_jit_write_protect_np(0);
        @memcpy(self.bytes[0..src.len], src);
        if (builtin.os.tag == .macos) {
            pthread_jit_write_protect_np(1);
            sys_icache_invalidate(self.bytes.ptr, src.len);
        } else {
            std.posix.mprotect(self.bytes, .{ .READ = true, .EXEC = true }) catch return error.MapFailed;
            __clear_cache(self.bytes.ptr, self.bytes.ptr + src.len);
        }
    }

    pub fn unmap(self: *JitMemory) void {
        std.posix.munmap(self.bytes);
    }
};

// ------------------------------------------------------------ entry

/// Compiles a loaded (and validated) program. strides[slot] is the element
/// size of each array slot, known from the parameter kinds.
pub fn compile(gpa: Allocator, p: *const vm.Program, strides: *const [64]u32) Error!Code {
    var c = Compiler{
        .gpa = gpa,
        .p = p,
        .pc_label = try gpa.alloc(u32, p.code.len),
        .home_i = undefined,
        .home_f = undefined,
        .stride = strides.*,
        .l_epilogue = 0,
        .l_fault_index = 0,
        .l_fault_divide = 0,
    };
    defer c.deinit();
    // SLANG_KERNEL_JIT=nopin keeps every register in memory (the course's
    // first stage), to measure what pinning is worth
    if (std.c.getenv("SLANG_KERNEL_JIT")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "nopin")) {
            @memset(&c.home_i, .mem);
            @memset(&c.home_f, .mem);
        } else c.plan();
    } else c.plan();
    c.l_epilogue = try c.newLabel();
    c.l_fault_index = try c.newLabel();
    c.l_fault_divide = try c.newLabel();
    for (c.pc_label) |*l| l.* = try c.newLabel();
    try c.prologue();
    var pc: u32 = 0;
    while (pc < p.code.len) {
        c.bind(c.pc_label[pc]);
        const op: Op = @enumFromInt(@as(u8, @truncate(p.code[pc])));
        try c.instruction(pc);
        pc += if (vm.hasWord(op)) 2 else 1;
    }
    try c.epilogue();
    try c.faults();
    try c.patch();
    if (std.c.getenv("SLANG_KERNEL_JIT")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "dump")) dump(p, c.code.items);
    }
    var mem = try JitMemory.map(c.code.items.len * 4);
    errdefer mem.unmap();
    try mem.write(c.code.items);
    return .{ .mem = mem, .func = @ptrCast(mem.bytes.ptr), .words = c.code.items.len };
}

pub fn free(code: *Code) void {
    code.mem.unmap();
}

/// The machine code as hex words, one per line, for
/// `llvm-mc --disassemble -triple=aarch64`.
fn dump(p: *const vm.Program, code: []const u32) void {
    std.debug.print("; kernel {s}: {d} words\n", .{ p.name, code.len });
    for (code) |w| {
        const b: [4]u8 = @bitCast(w);
        std.debug.print("0x{x:0>2} 0x{x:0>2} 0x{x:0>2} 0x{x:0>2}\n", .{ b[0], b[1], b[2], b[3] });
    }
}
