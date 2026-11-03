//! kernel/vm: the interpreter of kernel bytecode (see ../compiler.slang for
//! the format). A program is loaded once, checked so that it cannot reach
//! outside its registers, slots or code, and then called like a function:
//! its arguments go into registers and array slots, the code runs with
//! untagged int and float registers, and its result comes back.
//!
//! Built into ../lib/<platform>/vm.dylib by native/build.zig (the package
//! ships it prebuilt; see README.md).

const std = @import("std");
const c = @import("slang");

const tname = "kernel.Program";

// ------------------------------------------------------------ opcodes

// The order of compiler.slang's OPS (kernel.load compares the names).
const Op = enum(u8) {
    nop,
    movi,
    movf,
    addi,
    subi,
    muli,
    divi,
    modi,
    negi,
    andi,
    ori,
    xori,
    shli,
    shri,
    noti,
    addf,
    subf,
    mulf,
    divf,
    modf,
    negf,
    powf,
    madf,
    itof,
    ftoi,
    lti,
    lei,
    eqi,
    nei,
    ltf,
    lef,
    eqf,
    nef,
    notb,
    jmp,
    jt,
    jf,
    jlti,
    jlei,
    jeqi,
    jnei,
    jltf,
    jlef,
    jeqf,
    jnef,
    jnltf,
    jnlef,
    seli,
    self,
    len,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    exp,
    exp2,
    log,
    log2,
    sqrt,
    absf,
    floor,
    ceil,
    round,
    trunc,
    fract,
    tanh,
    sinh,
    cosh,
    signf,
    atan2,
    minf,
    maxf,
    mini,
    maxi,
    absi,
    signi,
    ret,
    reti,
    retf,
    ld_float,
    ld_double,
    ld_int8,
    ld_uint8,
    ld_int16,
    ld_uint16,
    ld_int32,
    ld_uint32,
    ld_int64,
    ld_uint64,
    ld_bool,
    st_float,
    st_double,
    st_int8,
    st_uint8,
    st_int16,
    st_uint16,
    st_int32,
    st_uint32,
    st_int64,
    st_uint64,
    st_bool,
    addi_jlti,
    addi_jlei,
    addi_jgti,
    addi_jgei,
};

const op_count = @typeInfo(Op).@"enum".field_names.len;

/// Whether an instruction has a word after it, and whether that word is a
/// jump target.
fn hasWord(op: Op) bool {
    return switch (op) {
        .jmp, .jt, .jf, .jlti, .jlei, .jeqi, .jnei, .jltf, .jlef, .jeqf, .jnef, .jnltf, .jnlef, .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei, .seli, .self, .madf => true,
        else => isLoad(op) or isStore(op),
    };
}

fn isJump(op: Op) bool {
    return switch (op) {
        .jmp, .jt, .jf, .jlti, .jlei, .jeqi, .jnei, .jltf, .jlef, .jeqf, .jnef, .jnltf, .jnlef, .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei => true,
        else => false,
    };
}

fn isLoad(op: Op) bool {
    const x = @intFromEnum(op);
    return x >= @intFromEnum(Op.ld_float) and x <= @intFromEnum(Op.ld_bool);
}

fn isStore(op: Op) bool {
    const x = @intFromEnum(op);
    return x >= @intFromEnum(Op.st_float) and x <= @intFromEnum(Op.st_bool);
}

// storage kinds, in compiler.KINDS order; 11 is an array of structs
const kind_names = [_][]const u8{ "float", "double", "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "bool" };
const kind_sizes = [_]usize{ 4, 8, 1, 1, 2, 2, 4, 4, 8, 8, 1 };
const STRUCT_KIND = 11;

// parameter kinds
const P_INT = 1;
const P_FLOAT = 2;
const P_BOOL = 3;
const P_ARRAY = 4;
const P_STRUCT = 5;

// ------------------------------------------------------------ programs

const Param = struct { kind: i32, index: i32, elem: i32, size: i32 };
const Const = struct { reg: u8, int: i64, float: f64 };

const Program = struct {
    code: []u32,
    iconsts: []Const,
    fconsts: []Const,
    params: []Param,
    lines: []i32,
    ret: i32,
    slots: usize,
    name: [:0]u8,
    origin: [:0]u8,
};

const Slot = struct { base: [*]u8, len: u64, stride: u64 };

const gpa = std.heap.c_allocator;

// libm's, which are faster than std.math's generic versions
extern fn tanh(x: f64) f64;
extern fn sinh(x: f64) f64;
extern fn cosh(x: f64) f64;
extern fn asin(x: f64) f64;
extern fn acos(x: f64) f64;
extern fn atan(x: f64) f64;
extern fn atan2(y: f64, x: f64) f64;
extern fn pow(x: f64, y: f64) f64;

fn freeProgram(data: ?*anyopaque) callconv(.c) void {
    const holder: *?*Program = @ptrCast(@alignCast(data orelse return));
    const p = holder.* orelse return;
    gpa.free(p.code);
    gpa.free(p.iconsts);
    gpa.free(p.fconsts);
    gpa.free(p.params);
    gpa.free(p.lines);
    gpa.free(p.name);
    gpa.free(p.origin);
    gpa.destroy(p);
    holder.* = null;
}

/// A buffer argument's elements as a slice of T, or null (an error is set).
fn bufferArg(S: ?*c.slang_State, idx: c_int, comptime T: type, what: [*:0]const u8, name: [*:0]const u8) ?[]T {
    var count: usize = 0;
    var size: usize = 0;
    const ptr = c.slang_tobuffer(S, idx, &count, &size) orelse {
        _ = c.slang_error(S, "kernel.load: %s must be a buffer", what);
        return null;
    };
    const ty = c.slang_buffertype(S, idx);
    if (ty == null or !std.mem.eql(u8, std.mem.span(ty), std.mem.span(name))) {
        _ = c.slang_error(S, "kernel.load: %s must be a buffer of %s", what, name);
        return null;
    }
    const p: [*]T = @ptrCast(@alignCast(ptr));
    return p[0..count];
}

fn dupeZ(s: [*c]const u8) [:0]u8 {
    const span = std.mem.span(s);
    const out = gpa.allocSentinel(u8, span.len, 0) catch @panic("out of memory");
    @memcpy(out, span);
    return out;
}

/// load(code, iconsts, fregs, fvals, params, lines, ret, slots, name,
/// origin) -> program: buffers of uint32 code, int64 (register, value)
/// pairs, int32 float registers, double float values, int32 parameter
/// quadruples (kind, register or slot, element kind, element size) and
/// int32 (pc, line) pairs.
fn load(S: ?*c.slang_State) callconv(.c) c_int {
    const code = bufferArg(S, 1, u32, "code", "uint32") orelse return c.SLANG_ERROR;
    const iconsts = bufferArg(S, 2, i64, "iconsts", "int64") orelse return c.SLANG_ERROR;
    const fregs = bufferArg(S, 3, i32, "fregs", "int32") orelse return c.SLANG_ERROR;
    const fvals = bufferArg(S, 4, f64, "fvals", "double") orelse return c.SLANG_ERROR;
    const params = bufferArg(S, 5, i32, "params", "int32") orelse return c.SLANG_ERROR;
    const lines = bufferArg(S, 6, i32, "lines", "int32") orelse return c.SLANG_ERROR;
    const ret = c.slang_checkint(S, 7);
    const slots = c.slang_checkint(S, 8);
    const name = c.slang_checklstring(S, 9, null);
    const origin = c.slang_checklstring(S, 10, null);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    if (fregs.len != fvals.len or iconsts.len % 2 != 0 or params.len % 4 != 0 or lines.len % 2 != 0)
        return c.slang_error(S, "kernel.load: malformed program");
    if (slots < 0 or slots > 64) return c.slang_error(S, "kernel.load: at most 64 arrays");
    if (code.len == 0) return c.slang_error(S, "kernel.load: no code");

    // the code: known opcodes, whole instructions, jumps to instruction
    // starts, slots that exist, and no way to run off the end
    const starts = gpa.alloc(bool, code.len + 1) catch @panic("out of memory");
    defer gpa.free(starts);
    @memset(starts, false);
    var pc: usize = 0;
    var last: Op = .nop;
    while (pc < code.len) {
        const raw = code[pc] & 0xff;
        if (raw >= op_count) return c.slang_error(S, "kernel.load: unknown opcode %d at %d", @as(c_int, @intCast(raw)), @as(c_int, @intCast(pc)));
        const op: Op = @enumFromInt(raw);
        starts[pc] = true;
        const size: usize = if (hasWord(op)) 2 else 1;
        if (pc + size > code.len) return c.slang_error(S, "kernel.load: truncated instruction at %d", @as(c_int, @intCast(pc)));
        if (isLoad(op) or isStore(op) or op == .len) {
            const slot = if (isStore(op)) (code[pc] >> 8) & 0xff else (code[pc] >> 16) & 0xff;
            if (slot >= slots) return c.slang_error(S, "kernel.load: slot %d out of range at %d", @as(c_int, @intCast(slot)), @as(c_int, @intCast(pc)));
        }
        last = op;
        pc += size;
    }
    if (last != .ret and last != .reti and last != .retf and last != .jmp)
        return c.slang_error(S, "kernel.load: the code does not end with a return");
    pc = 0;
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc] & 0xff);
        if (isJump(op)) {
            const target = code[pc + 1];
            if (target >= code.len or !starts[target]) return c.slang_error(S, "kernel.load: bad jump target at %d", @as(c_int, @intCast(pc)));
        }
        pc += if (hasWord(op)) 2 else 1;
    }
    for (0..params.len / 4) |k| {
        const kind = params[k * 4];
        const index = params[k * 4 + 1];
        const elem = params[k * 4 + 2];
        if (kind < P_INT or kind > P_STRUCT or index < 0 or index > 255)
            return c.slang_error(S, "kernel.load: malformed parameter %d", @as(c_int, @intCast(k)));
        if ((kind == P_ARRAY or kind == P_STRUCT) and (index >= slots or elem < 0 or elem > STRUCT_KIND))
            return c.slang_error(S, "kernel.load: malformed parameter %d", @as(c_int, @intCast(k)));
    }
    for (fregs) |r| {
        if (r < 0 or r > 255) return c.slang_error(S, "kernel.load: malformed constants");
    }

    const p = gpa.create(Program) catch @panic("out of memory");
    p.* = .{
        .code = gpa.dupe(u32, code) catch @panic("out of memory"),
        .iconsts = gpa.alloc(Const, iconsts.len / 2) catch @panic("out of memory"),
        .fconsts = gpa.alloc(Const, fregs.len) catch @panic("out of memory"),
        .params = gpa.alloc(Param, params.len / 4) catch @panic("out of memory"),
        .lines = gpa.dupe(i32, lines) catch @panic("out of memory"),
        .ret = @intCast(ret),
        .slots = @intCast(slots),
        .name = dupeZ(name),
        .origin = dupeZ(origin),
    };
    for (p.iconsts, 0..) |*k, i| {
        k.* = .{ .reg = @intCast(iconsts[i * 2] & 0xff), .int = iconsts[i * 2 + 1], .float = 0 };
    }
    for (p.fconsts, 0..) |*k, i| {
        k.* = .{ .reg = @intCast(fregs[i]), .int = 0, .float = fvals[i] };
    }
    for (p.params, 0..) |*q, i| {
        q.* = .{ .kind = params[i * 4], .index = params[i * 4 + 1], .elem = params[i * 4 + 2], .size = params[i * 4 + 3] };
    }
    const holder: *?*Program = @ptrCast(@alignCast(c.slang_newuserdata(S, @sizeOf(?*Program), tname, freeProgram)));
    holder.* = p;
    return 1;
}

// ------------------------------------------------------------ running

const Fault = enum { none, index, divide };

const Outcome = struct { fault: Fault = .none, pc: u32 = 0, index: i64 = 0, len: u64 = 0 };

inline fn ra(w: u32) u8 {
    return @truncate(w >> 8);
}
inline fn rb(w: u32) u8 {
    return @truncate(w >> 16);
}
inline fn rc(w: u32) u8 {
    return @truncate(w >> 24);
}

fn floorDiv(x: i64, y: i64) i64 {
    if (y == -1) return 0 -% x;
    const q = @divTrunc(x, y);
    if ((x - q * y != 0) and ((x < 0) != (y < 0))) return q - 1;
    return q;
}

fn floorMod(x: i64, y: i64) i64 {
    if (y == -1) return 0;
    const r = x - @divTrunc(x, y) * y;
    if (r != 0 and ((r < 0) != (y < 0))) return r + y;
    return r;
}

fn toInt(x: f64) i64 {
    if (x != x) return 0;
    if (x >= 9.2233720368547758e18) return std.math.maxInt(i64);
    if (x <= -9.2233720368547758e18) return std.math.minInt(i64);
    return @intFromFloat(x);
}

fn signF(x: f64) f64 {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return x;
}

/// The address of an element (the index checked), or null.
inline fn addr(s: *const Slot, idx: i64, off: u32) ?[*]u8 {
    const i: u64 = @bitCast(idx);
    if (i >= s.len) return null;
    return s.base + @as(usize, @intCast(i * s.stride)) + off;
}

fn readAs(comptime T: type, p: [*]u8) T {
    return @as(*align(1) const T, @ptrCast(p)).*;
}

fn writeAs(comptime T: type, p: [*]u8, v: T) void {
    @as(*align(1) T, @ptrCast(p)).* = v;
}

/// Runs the code; the result is in I[ret] or F[ret] for a reti or retf.
fn exec(code: [*]const u32, I: *[256]i64, F: *[256]f64, slots: *const [64]Slot, out: *Outcome) u8 {
    var pc: u32 = 0;
    var w: u32 = code[0];
    sw: switch (@as(Op, @enumFromInt(@as(u8, @truncate(w))))) {
        .nop => {
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .movi => {
            I[ra(w)] = I[rb(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .movf => {
            F[ra(w)] = F[rb(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .addi => {
            I[ra(w)] = I[rb(w)] +% I[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .subi => {
            I[ra(w)] = I[rb(w)] -% I[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .muli => {
            I[ra(w)] = I[rb(w)] *% I[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .divi => {
            const y = I[rc(w)];
            if (y == 0) {
                out.* = .{ .fault = .divide, .pc = pc };
                return 0;
            }
            I[ra(w)] = floorDiv(I[rb(w)], y);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .modi => {
            const y = I[rc(w)];
            if (y == 0) {
                out.* = .{ .fault = .divide, .pc = pc };
                return 0;
            }
            I[ra(w)] = floorMod(I[rb(w)], y);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .negi => {
            I[ra(w)] = 0 -% I[rb(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .andi => {
            I[ra(w)] = I[rb(w)] & I[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .ori => {
            I[ra(w)] = I[rb(w)] | I[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .xori => {
            I[ra(w)] = I[rb(w)] ^ I[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .shli => {
            const sh: u6 = @truncate(@as(u64, @bitCast(I[rc(w)])));
            I[ra(w)] = @bitCast(@as(u64, @bitCast(I[rb(w)])) << sh);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .shri => {
            const sh: u6 = @truncate(@as(u64, @bitCast(I[rc(w)])));
            I[ra(w)] = I[rb(w)] >> sh;
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .noti => {
            I[ra(w)] = ~I[rb(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .addf => {
            F[ra(w)] = F[rb(w)] + F[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .subf => {
            F[ra(w)] = F[rb(w)] - F[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .mulf => {
            F[ra(w)] = F[rb(w)] * F[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .divf => {
            F[ra(w)] = F[rb(w)] / F[rc(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .modf => {
            const x = F[rb(w)];
            const y = F[rc(w)];
            F[ra(w)] = x - y * @floor(x / y);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .negf => {
            F[ra(w)] = -F[rb(w)];
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .powf => {
            F[ra(w)] = pow(F[rb(w)], F[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .madf => {
            F[ra(w)] = F[rb(w)] + F[rc(w)] * F[code[pc + 1]];
            pc += 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .itof => {
            F[ra(w)] = @floatFromInt(I[rb(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .ftoi => {
            I[ra(w)] = toInt(F[rb(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .lti => {
            I[ra(w)] = @intFromBool(I[rb(w)] < I[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .lei => {
            I[ra(w)] = @intFromBool(I[rb(w)] <= I[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .eqi => {
            I[ra(w)] = @intFromBool(I[rb(w)] == I[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .nei => {
            I[ra(w)] = @intFromBool(I[rb(w)] != I[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .ltf => {
            I[ra(w)] = @intFromBool(F[rb(w)] < F[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .lef => {
            I[ra(w)] = @intFromBool(F[rb(w)] <= F[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .eqf => {
            I[ra(w)] = @intFromBool(F[rb(w)] == F[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .nef => {
            I[ra(w)] = @intFromBool(F[rb(w)] != F[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .notb => {
            I[ra(w)] = @intFromBool(I[rb(w)] == 0);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jmp => {
            pc = code[pc + 1];
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jt => {
            pc = if (I[ra(w)] != 0) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jf => {
            pc = if (I[ra(w)] == 0) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jlti => {
            pc = if (I[ra(w)] < I[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jlei => {
            pc = if (I[ra(w)] <= I[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jeqi => {
            pc = if (I[ra(w)] == I[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jnei => {
            pc = if (I[ra(w)] != I[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jltf => {
            pc = if (F[ra(w)] < F[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jlef => {
            pc = if (F[ra(w)] <= F[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jeqf => {
            pc = if (F[ra(w)] == F[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jnef => {
            pc = if (F[ra(w)] != F[rb(w)]) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jnltf => {
            pc = if (!(F[ra(w)] < F[rb(w)])) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .jnlef => {
            pc = if (!(F[ra(w)] <= F[rb(w)])) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .seli => {
            I[ra(w)] = if (I[code[pc + 1] & 0xff] != 0) I[rb(w)] else I[rc(w)];
            pc += 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .self => {
            F[ra(w)] = if (I[code[pc + 1] & 0xff] != 0) F[rb(w)] else F[rc(w)];
            pc += 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .len => {
            I[ra(w)] = @intCast(slots[rb(w)].len);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        inline .sin, .cos, .tan, .asin, .acos, .atan, .exp, .exp2, .log, .log2, .sqrt, .absf, .floor, .ceil, .round, .trunc, .fract, .tanh, .sinh, .cosh, .signf => |op| {
            const x = F[rb(w)];
            F[ra(w)] = switch (op) {
                .sin => @sin(x),
                .cos => @cos(x),
                .tan => @tan(x),
                .asin => asin(x),
                .acos => acos(x),
                .atan => atan(x),
                .exp => @exp(x),
                .exp2 => @exp2(x),
                .log => @log(x),
                .log2 => @log2(x),
                .sqrt => @sqrt(x),
                .absf => @abs(x),
                .floor => @floor(x),
                .ceil => @ceil(x),
                .round => @round(x),
                .trunc => @trunc(x),
                .fract => x - @floor(x),
                .tanh => tanh(x),
                .sinh => sinh(x),
                .cosh => cosh(x),
                .signf => signF(x),
                else => unreachable,
            };
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .atan2 => {
            F[ra(w)] = atan2(F[rb(w)], F[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .minf => {
            const x = F[rb(w)];
            const y = F[rc(w)];
            F[ra(w)] = if (y < x) y else x;
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .maxf => {
            const x = F[rb(w)];
            const y = F[rc(w)];
            F[ra(w)] = if (y > x) y else x;
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .mini => {
            I[ra(w)] = @min(I[rb(w)], I[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .maxi => {
            I[ra(w)] = @max(I[rb(w)], I[rc(w)]);
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .absi => {
            const x = I[rb(w)];
            I[ra(w)] = if (x < 0) 0 -% x else x;
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .signi => {
            const x = I[rb(w)];
            I[ra(w)] = if (x > 0) 1 else if (x < 0) -1 else 0;
            pc += 1;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        .ret => return 0,
        .reti => return ra(w),
        .retf => return ra(w),
        inline .ld_float, .ld_double, .ld_int8, .ld_uint8, .ld_int16, .ld_uint16, .ld_int32, .ld_uint32, .ld_int64, .ld_uint64, .ld_bool => |op| {
            const idx = I[rc(w)];
            const s = &slots[rb(w)];
            const p = addr(s, idx, code[pc + 1]) orelse {
                out.* = .{ .fault = .index, .pc = pc, .index = idx, .len = s.len };
                return 0;
            };
            switch (op) {
                .ld_float => F[ra(w)] = readAs(f32, p),
                .ld_double => F[ra(w)] = readAs(f64, p),
                .ld_int8 => I[ra(w)] = readAs(i8, p),
                .ld_uint8 => I[ra(w)] = readAs(u8, p),
                .ld_int16 => I[ra(w)] = readAs(i16, p),
                .ld_uint16 => I[ra(w)] = readAs(u16, p),
                .ld_int32 => I[ra(w)] = readAs(i32, p),
                .ld_uint32 => I[ra(w)] = readAs(u32, p),
                .ld_int64 => I[ra(w)] = readAs(i64, p),
                .ld_uint64 => I[ra(w)] = @bitCast(readAs(u64, p)),
                .ld_bool => I[ra(w)] = @intFromBool(readAs(u8, p) != 0),
                else => unreachable,
            }
            pc += 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        inline .st_float, .st_double, .st_int8, .st_uint8, .st_int16, .st_uint16, .st_int32, .st_uint32, .st_int64, .st_uint64, .st_bool => |op| {
            // st slot, index, value
            const idx = I[rb(w)];
            const s = &slots[ra(w)];
            const p = addr(s, idx, code[pc + 1]) orelse {
                out.* = .{ .fault = .index, .pc = pc, .index = idx, .len = s.len };
                return 0;
            };
            const v = rc(w);
            switch (op) {
                .st_float => writeAs(f32, p, @floatCast(F[v])),
                .st_double => writeAs(f64, p, F[v]),
                .st_int8 => writeAs(i8, p, @truncate(I[v])),
                .st_uint8 => writeAs(u8, p, @truncate(@as(u64, @bitCast(I[v])))),
                .st_int16 => writeAs(i16, p, @truncate(I[v])),
                .st_uint16 => writeAs(u16, p, @truncate(@as(u64, @bitCast(I[v])))),
                .st_int32 => writeAs(i32, p, @truncate(I[v])),
                .st_uint32 => writeAs(u32, p, @truncate(@as(u64, @bitCast(I[v])))),
                .st_int64 => writeAs(i64, p, I[v]),
                .st_uint64 => writeAs(u64, p, @bitCast(I[v])),
                .st_bool => writeAs(u8, p, @intFromBool(I[v] != 0)),
                else => unreachable,
            }
            pc += 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
        inline .addi_jlti, .addi_jlei, .addi_jgti, .addi_jgei => |op| {
            // I[a] += I[b]; jump while I[a] compares to I[c]
            const i = I[ra(w)] +% I[rb(w)];
            I[ra(w)] = i;
            const n = I[rc(w)];
            const more = switch (op) {
                .addi_jlti => i < n,
                .addi_jlei => i <= n,
                .addi_jgti => i > n,
                .addi_jgei => i >= n,
                else => unreachable,
            };
            pc = if (more) code[pc + 1] else pc + 2;
            w = code[pc];
            continue :sw @enumFromInt(@as(u8, @truncate(w)));
        },
    }
}

/// The line of the instruction at pc.
fn lineOf(p: *const Program, pc: u32) i32 {
    var line: i32 = 0;
    var k: usize = 0;
    while (k + 1 < p.lines.len) : (k += 2) {
        if (p.lines[k] > pc) break;
        line = p.lines[k + 1];
    }
    return line;
}

/// program(...args) -> the kernel's result (or null)
fn call(S: ?*c.slang_State) callconv(.c) c_int {
    const holder: *?*Program = @ptrCast(@alignCast(c.slang_checkudata(S, 1, tname) orelse return c.SLANG_ERROR));
    const p = holder.* orelse return c.slang_error(S, "kernel: the program was freed");
    const given = c.slang_gettop(S) - 1;
    if (given != @as(c_int, @intCast(p.params.len)))
        return c.slang_error(S, "kernel %s takes %d arguments, got %d", p.name.ptr, @as(c_int, @intCast(p.params.len)), given);
    var I: [256]i64 = undefined;
    var F: [256]f64 = undefined;
    var slots: [64]Slot = undefined;
    for (p.iconsts) |k| I[k.reg] = k.int;
    for (p.fconsts) |k| F[k.reg] = k.float;
    for (p.params, 0..) |q, k| {
        const idx: c_int = @intCast(k + 2);
        const at: u8 = @intCast(q.index);
        switch (q.kind) {
            P_INT => {
                if (!c.slang_isint(S, idx)) return argError(S, p, k, "an int");
                I[at] = c.slang_toint(S, idx);
            },
            P_FLOAT => {
                const t = c.slang_type(S, idx);
                if (t != c.SLANG_TINT and t != c.SLANG_TDOUBLE) return argError(S, p, k, "a number");
                F[at] = c.slang_todouble(S, idx);
            },
            P_BOOL => {
                if (c.slang_type(S, idx) != c.SLANG_TBOOL) return argError(S, p, k, "a bool");
                I[at] = @intFromBool(c.slang_tobool(S, idx));
            },
            else => {
                var count: usize = 0;
                var size: usize = 0;
                const ptr = c.slang_tobuffer(S, idx, &count, &size) orelse return argError(S, p, k, "a buffer");
                const ty = std.mem.span(c.slang_buffertype(S, idx));
                const elem: usize = @intCast(q.elem);
                if (elem == STRUCT_KIND) {
                    if (!std.mem.eql(u8, ty, "struct") or size != @as(usize, @intCast(q.size)))
                        return argError(S, p, k, "a buffer of its struct");
                } else if (!std.mem.eql(u8, ty, kind_names[elem])) {
                    return c.slang_error(S, "kernel %s: argument %d must be a buffer of %s, got one of %s", p.name.ptr, @as(c_int, @intCast(k + 1)), kind_names[elem].ptr, ty.ptr);
                }
                if (q.kind == P_STRUCT and count == 0) return argError(S, p, k, "a buffer with an element");
                slots[at] = .{ .base = @ptrCast(ptr), .len = count, .stride = size };
            },
        }
    }
    var out: Outcome = .{};
    const r = exec(p.code.ptr, &I, &F, &slots, &out);
    switch (out.fault) {
        .none => {},
        .index => return c.slang_error(S, "%s:%d: kernel %s: index %lld out of range (length %llu)", p.origin.ptr, lineOf(p, out.pc), p.name.ptr, @as(c_longlong, out.index), @as(c_ulonglong, out.len)),
        .divide => return c.slang_error(S, "%s:%d: kernel %s: integer division by zero", p.origin.ptr, lineOf(p, out.pc), p.name.ptr),
    }
    switch (p.ret) {
        P_INT => c.slang_pushint(S, I[r]),
        P_FLOAT => c.slang_pushdouble(S, F[r]),
        P_BOOL => c.slang_pushbool(S, I[r] != 0),
        else => return 0,
    }
    return 1;
}

fn argError(S: ?*c.slang_State, p: *const Program, k: usize, what: [*:0]const u8) c_int {
    return c.slang_error(S, "kernel %s: argument %d must be %s", p.name.ptr, @as(c_int, @intCast(k + 1)), what);
}

/// op_names() -> {string}: the opcodes in order (kernel.load compares them
/// with the compiler's)
fn opNames(S: ?*c.slang_State) callconv(.c) c_int {
    c.slang_newtable(S);
    inline for (@typeInfo(Op).@"enum".field_names, 0..) |f, i| {
        c.slang_pushstring(S, f);
        _ = c.slang_seti(S, -2, i);
    }
    return 1;
}

const meta = [_]c.slang_Reg{
    .{ .name = "__call", .func = call },
    .{ .name = null, .func = null },
};

const funcs = [_]c.slang_Reg{
    .{ .name = "load", .func = load },
    .{ .name = "op_names", .func = opNames },
    .{ .name = null, .func = null },
};

export fn slang_ext_version_kernel_vm() c_int {
    return c.SLANG_API_VERSION;
}

export fn slang_open_kernel_vm(S: ?*c.slang_State) c_int {
    c.slang_newmodule(S, &meta);
    c.slang_pushstring(S, "kernel.Program");
    _ = c.slang_setfield(S, -2, "__type");
    c.slang_settypemeta(S, tname);
    c.slang_newmodule(S, &funcs);
    return 1;
}
