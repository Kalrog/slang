//! An AArch64 (arm64) instruction encoder: the few dozen instruction forms
//! the kernel JIT emits, each as a function that returns the 32-bit word.
//!
//! Every instruction is one 32-bit word. The fields are at fixed bit
//! positions, so an encoding is a base pattern (the opcode bits) ORed with
//! the register numbers and immediates shifted into place. The comments
//! give the assembler syntax, as `llvm-mc --disassemble` prints it, which
//! is how the encoder is checked (see test/encodings.sh).
//!
//! Registers are numbers: x0..x30 are 0..30, and 31 is either the zero
//! register (xzr) or the stack pointer (sp) depending on the instruction.
//! d0..d31 are 0..31 in the float instructions.
const std = @import("std");

pub const Reg = u5;
pub const xzr: Reg = 31;
pub const sp: Reg = 31;
pub const fp: Reg = 29;
pub const lr: Reg = 30;

/// Condition codes, as b.cond, csel, cset and fcsel take them.
pub const Cond = enum(u4) {
    eq = 0, // equal (Z set)
    ne = 1, // not equal
    hs = 2, // unsigned higher or same (C set)
    lo = 3, // unsigned lower
    mi = 4, // negative (N set); for fcmp: less than
    pl = 5, // positive or zero; for fcmp: not less than (includes NaN)
    vs = 6, // overflow
    vc = 7, // no overflow
    hi = 8, // unsigned higher; for fcmp: not less or equal (includes NaN)
    ls = 9, // unsigned lower or same; for fcmp: less or equal
    ge = 10, // signed greater or equal; for fcmp: greater or equal
    lt = 11, // signed less than; for fcmp: less than or unordered
    gt = 12, // signed greater than; for fcmp: greater than
    le = 13, // signed less or equal; for fcmp: less, equal or unordered
    al = 14, // always

    pub fn invert(c: Cond) Cond {
        return @enumFromInt(@intFromEnum(c) ^ 1);
    }
};

inline fn r(x: Reg) u32 {
    return @as(u32, x);
}

// ------------------------------------------------------------ integer ALU

/// add xd, xn, xm
pub fn add(d: Reg, n: Reg, m: Reg) u32 {
    return 0x8B000000 | r(m) << 16 | r(n) << 5 | r(d);
}
/// add xd, xn, xm, lsl #sh
pub fn addShifted(d: Reg, n: Reg, m: Reg, sh: u6) u32 {
    return 0x8B000000 | r(m) << 16 | @as(u32, sh) << 10 | r(n) << 5 | r(d);
}
/// sub xd, xn, xm
pub fn sub(d: Reg, n: Reg, m: Reg) u32 {
    return 0xCB000000 | r(m) << 16 | r(n) << 5 | r(d);
}
/// neg xd, xm  (sub xd, xzr, xm)
pub fn neg(d: Reg, m: Reg) u32 {
    return sub(d, xzr, m);
}
/// add xd, xn, #imm12
pub fn addImm(d: Reg, n: Reg, imm: u12) u32 {
    return 0x91000000 | @as(u32, imm) << 10 | r(n) << 5 | r(d);
}
/// sub xd, xn, #imm12
pub fn subImm(d: Reg, n: Reg, imm: u12) u32 {
    return 0xD1000000 | @as(u32, imm) << 10 | r(n) << 5 | r(d);
}
/// cmp xn, xm  (subs xzr, xn, xm)
pub fn cmp(n: Reg, m: Reg) u32 {
    return 0xEB000000 | r(m) << 16 | r(n) << 5 | r(xzr);
}
/// cmp xn, #imm12  (subs xzr, xn, #imm)
pub fn cmpImm(n: Reg, imm: u12) u32 {
    return 0xF1000000 | @as(u32, imm) << 10 | r(n) << 5 | r(xzr);
}
/// mul xd, xn, xm  (madd xd, xn, xm, xzr)
pub fn mul(d: Reg, n: Reg, m: Reg) u32 {
    return madd(d, n, m, xzr);
}
/// madd xd, xn, xm, xa  (xd = xa + xn * xm)
pub fn madd(d: Reg, n: Reg, m: Reg, a: Reg) u32 {
    return 0x9B000000 | r(m) << 16 | r(a) << 10 | r(n) << 5 | r(d);
}
/// msub xd, xn, xm, xa  (xd = xa - xn * xm)
pub fn msub(d: Reg, n: Reg, m: Reg, a: Reg) u32 {
    return 0x9B008000 | r(m) << 16 | r(a) << 10 | r(n) << 5 | r(d);
}
/// sdiv xd, xn, xm
pub fn sdiv(d: Reg, n: Reg, m: Reg) u32 {
    return 0x9AC00C00 | r(m) << 16 | r(n) << 5 | r(d);
}
/// and xd, xn, xm
pub fn and_(d: Reg, n: Reg, m: Reg) u32 {
    return 0x8A000000 | r(m) << 16 | r(n) << 5 | r(d);
}
/// orr xd, xn, xm
pub fn orr(d: Reg, n: Reg, m: Reg) u32 {
    return 0xAA000000 | r(m) << 16 | r(n) << 5 | r(d);
}
/// eor xd, xn, xm
pub fn eor(d: Reg, n: Reg, m: Reg) u32 {
    return 0xCA000000 | r(m) << 16 | r(n) << 5 | r(d);
}
/// mvn xd, xm  (orn xd, xzr, xm)
pub fn mvn(d: Reg, m: Reg) u32 {
    return 0xAA200000 | r(m) << 16 | r(xzr) << 5 | r(d);
}
/// mov xd, xm  (orr xd, xzr, xm)
pub fn mov(d: Reg, m: Reg) u32 {
    return orr(d, xzr, m);
}
/// lsl xd, xn, xm  (lslv: the shift is xm mod 64)
pub fn lslv(d: Reg, n: Reg, m: Reg) u32 {
    return 0x9AC02000 | r(m) << 16 | r(n) << 5 | r(d);
}
/// asr xd, xn, xm  (asrv)
pub fn asrv(d: Reg, n: Reg, m: Reg) u32 {
    return 0x9AC02800 | r(m) << 16 | r(n) << 5 | r(d);
}
/// csel xd, xn, xm, cond  (xd = cond ? xn : xm)
pub fn csel(d: Reg, n: Reg, m: Reg, c: Cond) u32 {
    return 0x9A800000 | r(m) << 16 | @as(u32, @intFromEnum(c)) << 12 | r(n) << 5 | r(d);
}
/// csinc xd, xn, xm, cond  (xd = cond ? xn : xm + 1)
pub fn csinc(d: Reg, n: Reg, m: Reg, c: Cond) u32 {
    return 0x9A800400 | r(m) << 16 | @as(u32, @intFromEnum(c)) << 12 | r(n) << 5 | r(d);
}
/// csneg xd, xn, xm, cond  (xd = cond ? xn : -xm)
pub fn csneg(d: Reg, n: Reg, m: Reg, c: Cond) u32 {
    return 0xDA800400 | r(m) << 16 | @as(u32, @intFromEnum(c)) << 12 | r(n) << 5 | r(d);
}
/// cset xd, cond  (csinc xd, xzr, xzr, !cond)
pub fn cset(d: Reg, c: Cond) u32 {
    return csinc(d, xzr, xzr, c.invert());
}
/// cneg xd, xn, cond  (csneg xd, xn, xn, !cond)
pub fn cneg(d: Reg, n: Reg, c: Cond) u32 {
    return csneg(d, n, n, c.invert());
}

// ------------------------------------------------------------ immediates

/// movz xd, #imm16, lsl #(16 * hw)
pub fn movz(d: Reg, imm: u16, hw: u2) u32 {
    return 0xD2800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | r(d);
}
/// movk xd, #imm16, lsl #(16 * hw)
pub fn movk(d: Reg, imm: u16, hw: u2) u32 {
    return 0xF2800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | r(d);
}
/// movn xd, #imm16, lsl #(16 * hw)  (xd = ~(imm << 16hw))
pub fn movn(d: Reg, imm: u16, hw: u2) u32 {
    return 0x92800000 | @as(u32, hw) << 21 | @as(u32, imm) << 5 | r(d);
}

/// The words that put a 64-bit constant into xd: movz then movk for each
/// further non-zero 16-bit chunk (up to 4 words). Returns how many.
pub fn movImm64(buf: *[4]u32, d: Reg, value: u64) usize {
    var n: usize = 0;
    var first = true;
    var hw: u2 = 0;
    while (true) : (hw += 1) {
        const chunk: u16 = @truncate(value >> (@as(u6, hw) * 16));
        if (chunk != 0 or (hw == 3 and first)) {
            buf[n] = if (first) movz(d, chunk, hw) else movk(d, chunk, hw);
            n += 1;
            first = false;
        }
        if (hw == 3) break;
    }
    if (first) {
        buf[0] = movz(d, 0, 0);
        n = 1;
    }
    return n;
}

// ------------------------------------------------------------ loads and stores

// Unsigned-offset forms: the immediate is scaled by the access size, so
// imm12 reaches 32760 bytes for 8-byte accesses.

/// ldr xt, [xn, #imm12 * 8]
pub fn ldrX(t: Reg, n: Reg, imm: u12) u32 {
    return 0xF9400000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// str xt, [xn, #imm12 * 8]
pub fn strX(t: Reg, n: Reg, imm: u12) u32 {
    return 0xF9000000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldr wt, [xn, #imm12 * 4]  (zero-extends)
pub fn ldrW(t: Reg, n: Reg, imm: u12) u32 {
    return 0xB9400000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// str wt, [xn, #imm12 * 4]
pub fn strW(t: Reg, n: Reg, imm: u12) u32 {
    return 0xB9000000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldrsw xt, [xn, #imm12 * 4]  (sign-extends 32 to 64)
pub fn ldrsw(t: Reg, n: Reg, imm: u12) u32 {
    return 0xB9800000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldrh wt, [xn, #imm12 * 2]
pub fn ldrh(t: Reg, n: Reg, imm: u12) u32 {
    return 0x79400000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// strh wt, [xn, #imm12 * 2]
pub fn strh(t: Reg, n: Reg, imm: u12) u32 {
    return 0x79000000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldrsh xt, [xn, #imm12 * 2]
pub fn ldrsh(t: Reg, n: Reg, imm: u12) u32 {
    return 0x79800000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldrb wt, [xn, #imm12]
pub fn ldrb(t: Reg, n: Reg, imm: u12) u32 {
    return 0x39400000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// strb wt, [xn, #imm12]
pub fn strb(t: Reg, n: Reg, imm: u12) u32 {
    return 0x39000000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldrsb xt, [xn, #imm12]
pub fn ldrsb(t: Reg, n: Reg, imm: u12) u32 {
    return 0x39800000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldr dt, [xn, #imm12 * 8]
pub fn ldrD(t: Reg, n: Reg, imm: u12) u32 {
    return 0xFD400000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// str dt, [xn, #imm12 * 8]
pub fn strD(t: Reg, n: Reg, imm: u12) u32 {
    return 0xFD000000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// ldr st, [xn, #imm12 * 4]
pub fn ldrS(t: Reg, n: Reg, imm: u12) u32 {
    return 0xBD400000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// str st, [xn, #imm12 * 4]
pub fn strS(t: Reg, n: Reg, imm: u12) u32 {
    return 0xBD000000 | @as(u32, imm) << 10 | r(n) << 5 | r(t);
}
/// stp xt, xt2, [xn, #imm7 * 8]  (signed offset)
pub fn stpX(t: Reg, t2: Reg, n: Reg, imm: i7) u32 {
    return 0xA9000000 | @as(u32, @as(u7, @bitCast(imm))) << 15 | r(t2) << 10 | r(n) << 5 | r(t);
}
/// ldp xt, xt2, [xn, #imm7 * 8]
pub fn ldpX(t: Reg, t2: Reg, n: Reg, imm: i7) u32 {
    return 0xA9400000 | @as(u32, @as(u7, @bitCast(imm))) << 15 | r(t2) << 10 | r(n) << 5 | r(t);
}
/// stp dt, dt2, [xn, #imm7 * 8]
pub fn stpD(t: Reg, t2: Reg, n: Reg, imm: i7) u32 {
    return 0x6D000000 | @as(u32, @as(u7, @bitCast(imm))) << 15 | r(t2) << 10 | r(n) << 5 | r(t);
}
/// ldp dt, dt2, [xn, #imm7 * 8]
pub fn ldpD(t: Reg, t2: Reg, n: Reg, imm: i7) u32 {
    return 0x6D400000 | @as(u32, @as(u7, @bitCast(imm))) << 15 | r(t2) << 10 | r(n) << 5 | r(t);
}

// ------------------------------------------------------------ branches

/// b #(imm26 * 4)  (relative to this instruction)
pub fn b(offset_words: i26) u32 {
    return 0x14000000 | @as(u32, @as(u26, @bitCast(offset_words)));
}
/// b.cond #(imm19 * 4)
pub fn bcond(c: Cond, offset_words: i19) u32 {
    return 0x54000000 | @as(u32, @as(u19, @bitCast(offset_words))) << 5 | @as(u32, @intFromEnum(c));
}
/// cbz xt, #(imm19 * 4)
pub fn cbz(t: Reg, offset_words: i19) u32 {
    return 0xB4000000 | @as(u32, @as(u19, @bitCast(offset_words))) << 5 | r(t);
}
/// cbnz xt, #(imm19 * 4)
pub fn cbnz(t: Reg, offset_words: i19) u32 {
    return 0xB5000000 | @as(u32, @as(u19, @bitCast(offset_words))) << 5 | r(t);
}
/// blr xn
pub fn blr(n: Reg) u32 {
    return 0xD63F0000 | r(n) << 5;
}
/// ret
pub const ret: u32 = 0xD65F03C0;
/// mov x29, sp  (add x29, sp, #0)
pub const movFpSp: u32 = 0x910003FD;
/// nop
pub const nop: u32 = 0xD503201F;

// ------------------------------------------------------------ floating point (double)

/// fadd dd, dn, dm
pub fn fadd(d: Reg, n: Reg, m: Reg) u32 {
    return 0x1E602800 | r(m) << 16 | r(n) << 5 | r(d);
}
/// fsub dd, dn, dm
pub fn fsub(d: Reg, n: Reg, m: Reg) u32 {
    return 0x1E603800 | r(m) << 16 | r(n) << 5 | r(d);
}
/// fmul dd, dn, dm
pub fn fmul(d: Reg, n: Reg, m: Reg) u32 {
    return 0x1E600800 | r(m) << 16 | r(n) << 5 | r(d);
}
/// fdiv dd, dn, dm
pub fn fdiv(d: Reg, n: Reg, m: Reg) u32 {
    return 0x1E601800 | r(m) << 16 | r(n) << 5 | r(d);
}
/// fmadd dd, dn, dm, da  (dd = da + dn * dm, one rounding)
pub fn fmadd(d: Reg, n: Reg, m: Reg, a: Reg) u32 {
    return 0x1F400000 | r(m) << 16 | r(a) << 10 | r(n) << 5 | r(d);
}
/// fmsub dd, dn, dm, da  (dd = da - dn * dm, one rounding)
pub fn fmsub(d: Reg, n: Reg, m: Reg, a: Reg) u32 {
    return 0x1F408000 | r(m) << 16 | r(a) << 10 | r(n) << 5 | r(d);
}
/// fneg dd, dn
pub fn fneg(d: Reg, n: Reg) u32 {
    return 0x1E614000 | r(n) << 5 | r(d);
}
/// fabs dd, dn
pub fn fabs(d: Reg, n: Reg) u32 {
    return 0x1E60C000 | r(n) << 5 | r(d);
}
/// fsqrt dd, dn
pub fn fsqrt(d: Reg, n: Reg) u32 {
    return 0x1E61C000 | r(n) << 5 | r(d);
}
/// fmov dd, dn
pub fn fmov(d: Reg, n: Reg) u32 {
    return 0x1E604000 | r(n) << 5 | r(d);
}
/// fmov dd, #1.0
pub fn fmovOne(d: Reg) u32 {
    return 0x1E601000 | @as(u32, 0x70) << 13 | r(d);
}
/// fmov dd, #-1.0
pub fn fmovMinusOne(d: Reg) u32 {
    return 0x1E601000 | @as(u32, 0xF0) << 13 | r(d);
}
/// frintm dd, dn  (round toward minus infinity: floor)
pub fn frintm(d: Reg, n: Reg) u32 {
    return 0x1E654000 | r(n) << 5 | r(d);
}
/// frintp dd, dn  (toward plus infinity: ceil)
pub fn frintp(d: Reg, n: Reg) u32 {
    return 0x1E64C000 | r(n) << 5 | r(d);
}
/// frintz dd, dn  (toward zero: trunc)
pub fn frintz(d: Reg, n: Reg) u32 {
    return 0x1E65C000 | r(n) << 5 | r(d);
}
/// frinta dd, dn  (to nearest, ties away from zero: round)
pub fn frinta(d: Reg, n: Reg) u32 {
    return 0x1E664000 | r(n) << 5 | r(d);
}
/// fcvt dd, sn  (single to double)
pub fn fcvtDS(d: Reg, n: Reg) u32 {
    return 0x1E22C000 | r(n) << 5 | r(d);
}
/// fcvt sd, dn  (double to single)
pub fn fcvtSD(d: Reg, n: Reg) u32 {
    return 0x1E624000 | r(n) << 5 | r(d);
}
/// scvtf dd, xn  (signed int to double)
pub fn scvtf(d: Reg, n: Reg) u32 {
    return 0x9E620000 | r(n) << 5 | r(d);
}
/// fcvtzs xd, dn  (double to int, toward zero, saturating, NaN to 0)
pub fn fcvtzs(d: Reg, n: Reg) u32 {
    return 0x9E780000 | r(n) << 5 | r(d);
}
/// fcmp dn, dm
pub fn fcmp(n: Reg, m: Reg) u32 {
    return 0x1E602000 | r(m) << 16 | r(n) << 5;
}
/// fcmp dn, #0.0
pub fn fcmpZero(n: Reg) u32 {
    return 0x1E602008 | r(n) << 5;
}
/// fcsel dd, dn, dm, cond
pub fn fcsel(d: Reg, n: Reg, m: Reg, c: Cond) u32 {
    return 0x1E600C00 | r(m) << 16 | @as(u32, @intFromEnum(c)) << 12 | r(n) << 5 | r(d);
}

// ------------------------------------------------------------ check

/// Prints "<hex> <asm>" lines for test/encodings.sh to compare against
/// llvm-mc.
pub fn main() void {
    const cases = [_]struct { u32, []const u8 }{
        .{ add(0, 1, 2), "add x0, x1, x2" },
        .{ addShifted(3, 4, 5, 3), "add x3, x4, x5, lsl #3" },
        .{ sub(6, 7, 8), "sub x6, x7, x8" },
        .{ neg(9, 10), "neg x9, x10" },
        .{ addImm(11, 12, 4095), "add x11, x12, #4095" },
        .{ subImm(13, 14, 16), "sub x13, x14, #16" },
        .{ cmp(15, 16), "cmp x15, x16" },
        .{ cmpImm(17, 0), "cmp x17, #0" },
        .{ mul(18, 19, 20), "mul x18, x19, x20" },
        .{ madd(21, 22, 23, 24), "madd x21, x22, x23, x24" },
        .{ msub(25, 26, 27, 28), "msub x25, x26, x27, x28" },
        .{ sdiv(0, 1, 2), "sdiv x0, x1, x2" },
        .{ and_(3, 4, 5), "and x3, x4, x5" },
        .{ orr(6, 7, 8), "orr x6, x7, x8" },
        .{ eor(9, 10, 11), "eor x9, x10, x11" },
        .{ mvn(12, 13), "mvn x12, x13" },
        .{ mov(14, 15), "mov x14, x15" },
        .{ lslv(16, 17, 18), "lsl x16, x17, x18" },
        .{ asrv(19, 20, 21), "asr x19, x20, x21" },
        .{ csel(22, 23, 24, .lt), "csel x22, x23, x24, lt" },
        .{ cset(25, .gt), "cset x25, gt" },
        .{ cneg(26, 27, .lt), "cneg x26, x27, lt" },
        .{ movz(0, 0x1234, 0), "mov x0, #4660" },
        .{ movk(0, 0x5678, 1), "movk x0, #22136, lsl #16" },
        .{ movn(1, 0, 0), "mov x1, #-1" },
        .{ ldrX(2, 19, 255), "ldr x2, [x19, #2040]" },
        .{ strX(3, 19, 1), "str x3, [x19, #8]" },
        .{ ldrW(4, 5, 2), "ldr w4, [x5, #8]" },
        .{ strW(6, 7, 3), "str w6, [x7, #12]" },
        .{ ldrsw(8, 9, 1), "ldrsw x8, [x9, #4]" },
        .{ ldrh(10, 11, 2), "ldrh w10, [x11, #4]" },
        .{ strh(12, 13, 1), "strh w12, [x13, #2]" },
        .{ ldrsh(14, 15, 3), "ldrsh x14, [x15, #6]" },
        .{ ldrb(16, 17, 5), "ldrb w16, [x17, #5]" },
        .{ strb(18, 19, 6), "strb w18, [x19, #6]" },
        .{ ldrsb(20, 21, 7), "ldrsb x20, [x21, #7]" },
        .{ ldrD(8, 20, 255), "ldr d8, [x20, #2040]" },
        .{ strD(9, 20, 0), "str d9, [x20]" },
        .{ ldrS(0, 14, 3), "ldr s0, [x14, #12]" },
        .{ strS(1, 14, 0), "str s1, [x14]" },
        .{ stpX(29, 30, sp, 0), "stp x29, x30, [sp]" },
        .{ ldpX(19, 20, sp, 2), "ldp x19, x20, [sp, #16]" },
        .{ stpD(8, 9, sp, 12), "stp d8, d9, [sp, #96]" },
        .{ ldpD(14, 15, sp, 18), "ldp d14, d15, [sp, #144]" },
        .{ b(4), "b #16" },
        .{ b(-2), "b #-8" },
        .{ bcond(.hs, 3), "b.hs #12" },
        .{ cbz(5, -1), "cbz x5, #-4" },
        .{ cbnz(6, 2), "cbnz x6, #8" },
        .{ blr(16), "blr x16" },
        .{ ret, "ret" },
        .{ movFpSp, "mov x29, sp" },
        .{ nop, "nop" },
        .{ fadd(0, 1, 2), "fadd d0, d1, d2" },
        .{ fsub(3, 4, 5), "fsub d3, d4, d5" },
        .{ fmul(6, 7, 8), "fmul d6, d7, d8" },
        .{ fdiv(9, 10, 11), "fdiv d9, d10, d11" },
        .{ fmadd(12, 13, 14, 15), "fmadd d12, d13, d14, d15" },
        .{ fmsub(16, 17, 18, 19), "fmsub d16, d17, d18, d19" },
        .{ fneg(20, 21), "fneg d20, d21" },
        .{ fabs(22, 23), "fabs d22, d23" },
        .{ fsqrt(24, 25), "fsqrt d24, d25" },
        .{ fmov(26, 27), "fmov d26, d27" },
        .{ fmovOne(28), "fmov d28, #1.00000000" },
        .{ fmovMinusOne(29), "fmov d29, #-1.00000000" },
        .{ frintm(0, 1), "frintm d0, d1" },
        .{ frintp(2, 3), "frintp d2, d3" },
        .{ frintz(4, 5), "frintz d4, d5" },
        .{ frinta(6, 7), "frinta d6, d7" },
        .{ fcvtDS(8, 9), "fcvt d8, s9" },
        .{ fcvtSD(10, 11), "fcvt s10, d11" },
        .{ scvtf(12, 13), "scvtf d12, x13" },
        .{ fcvtzs(14, 15), "fcvtzs x14, d15" },
        .{ fcmp(16, 17), "fcmp d16, d17" },
        .{ fcmpZero(18), "fcmp d18, #0.0" },
        .{ fcsel(19, 20, 21, .mi), "fcsel d19, d20, d21, mi" },
    };
    for (cases) |c| {
        std.debug.print("{x:0>8} {s}\n", .{ c[0], c[1] });
    }
}
