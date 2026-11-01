const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

var prng: std.Random.DefaultPrng = undefined;
var prng_ready = false;

/// slang/math.
pub fn module(vm: *VM) *Table {
    const t = stdlib.makeModule(vm, &.{
        .{ .name = "random", .f = mathRandom },
        stdlib.fast("round", unary(roundHalfAway)),
        stdlib.fast("floor", unary(m_floor)),
        stdlib.fast("ceil", unary(m_ceil)),
        stdlib.fast("abs", mathAbs),
        stdlib.fast("min", mathMin),
        stdlib.fast("max", mathMax),
        stdlib.fast("sqrt", unary(m_sqrt)),
        stdlib.fast("sin", unary(m_sin)),
        stdlib.fast("cos", unary(m_cos)),
        stdlib.fast("tan", unary(m_tan)),
        stdlib.fast("asin", unary(m_asin)),
        stdlib.fast("acos", unary(m_acos)),
        stdlib.fast("atan", unary(m_atan)),
        stdlib.fast("atan2", mathAtan2),
        stdlib.fast("log", mathLog),
        stdlib.fast("log2", unary(m_log2)),
        stdlib.fast("log10", unary(m_log10)),
        stdlib.fast("exp", unary(m_exp)),
        stdlib.fast("trunc", unary(m_trunc)),
        stdlib.fast("hypot", mathHypot),
        stdlib.fast("sinh", unary(m_sinh)),
        stdlib.fast("cosh", unary(m_cosh)),
        stdlib.fast("tanh", unary(m_tanh)),
        stdlib.fast("sign", mathSign),
        stdlib.fast("clamp", mathClamp),
        stdlib.fast("lerp", mathLerp),
        stdlib.fast("is_nan", mathIsNan),
        stdlib.fast("is_inf", mathIsInf),
        .{ .name = "random_int", .f = mathRandomInt },
        .{ .name = "seed", .f = mathSeed },
    });
    t.set(vm.gpa, vm.str("pi"), .{ .float = std.math.pi });
    t.set(vm.gpa, vm.str("e"), .{ .float = std.math.e });
    t.set(vm.gpa, vm.str("inf"), .{ .float = std.math.inf(f64) });
    t.set(vm.gpa, vm.str("nan"), .{ .float = std.math.nan(f64) });
    t.set(vm.gpa, vm.str("max_int"), .{ .int = std.math.maxInt(i64) });
    t.set(vm.gpa, vm.str("min_int"), .{ .int = std.math.minInt(i64) });
    return t;
}

fn m_floor(x: f64) f64 { return @floor(x); }
fn m_ceil(x: f64) f64 { return @ceil(x); }
fn m_sqrt(x: f64) f64 { return @sqrt(x); }
fn m_sin(x: f64) f64 { return @sin(x); }
fn m_cos(x: f64) f64 { return @cos(x); }
fn m_tan(x: f64) f64 { return @tan(x); }
fn m_asin(x: f64) f64 { return std.math.asin(x); }
fn m_acos(x: f64) f64 { return std.math.acos(x); }
fn m_atan(x: f64) f64 { return std.math.atan(x); }
fn m_exp(x: f64) f64 { return @exp(x); }
fn m_log2(x: f64) f64 { return @log2(x); }
fn m_log10(x: f64) f64 { return @log10(x); }
fn m_trunc(x: f64) f64 { return @trunc(x); }
fn m_sinh(x: f64) f64 { return std.math.sinh(x); }
fn m_cosh(x: f64) f64 { return std.math.cosh(x); }
fn m_tanh(x: f64) f64 { return std.math.tanh(x); }

fn logE(x: f64) f64 {
    return @log(x);
}

/// Go's math.Round: half away from zero.
fn roundHalfAway(x: f64) f64 {
    return @round(x);
}

fn unary(comptime f: fn (f64) f64) vm_mod.NativeFn {
    return struct {
        fn native(th: *Thread, args: []Value) Error!Value {
            const x = try api.argNumber(th, args, 0, "x");
            return .{ .float = f(x) };
        }
    }.native;
}

fn ensurePrng(th: *Thread) void {
    if (!prng_ready) {
        var seed: [8]u8 = undefined;
        th.vm.io.random(&seed);
        prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
        prng_ready = true;
    }
}

fn mathRandom(th: *Thread, args: []Value) Error!Value {
    ensurePrng(th);
    const lo = api.argNumberOr(args, 0, 0);
    const hi = api.argNumberOr(args, 1, 1);
    return .{ .float = prng.random().float(f64) * (hi - lo) + lo };
}

fn mathAbs(th: *Thread, args: []Value) Error!Value {
    const x = api.arg(args, 0);
    return switch (x) {
        .int => |i| .{ .int = if (i < 0) 0 -% i else i },
        .float => |f| .{ .float = @abs(f) },
        else => th.vm.raise("Expected num for x got {s}", .{x.typeName()}),
    };
}

fn mathMin(th: *Thread, args: []Value) Error!Value {
    var best: Value = .{ .float = std.math.inf(f64) };
    for (args, 0..) |a, i| {
        if (!a.isNumber()) return th.vm.raise("Expected num for argument {d} got {s}", .{ i, a.typeName() });
        if (a.asNumber() < best.asNumber()) best = a;
    }
    return best;
}

fn mathMax(th: *Thread, args: []Value) Error!Value {
    var best: Value = .{ .float = -std.math.inf(f64) };
    for (args, 0..) |a, i| {
        if (!a.isNumber()) return th.vm.raise("Expected num for argument {d} got {s}", .{ i, a.typeName() });
        if (a.asNumber() > best.asNumber()) best = a;
    }
    return best;
}

fn mathAtan2(th: *Thread, args: []Value) Error!Value {
    const y = try api.argNumber(th, args, 0, "y");
    const x = try api.argNumber(th, args, 1, "x");
    return .{ .float = std.math.atan2(y, x) };
}

/// log(x, [base]): the natural logarithm, or the logarithm in base.
fn mathLog(th: *Thread, args: []Value) Error!Value {
    const x = try api.argNumber(th, args, 0, "x");
    if (api.arg(args, 1) == .null) return .{ .float = logE(x) };
    const base = try api.argNumber(th, args, 1, "base");
    return .{ .float = @log(x) / @log(base) };
}

fn mathHypot(th: *Thread, args: []Value) Error!Value {
    const x = try api.argNumber(th, args, 0, "x");
    const y = try api.argNumber(th, args, 1, "y");
    return .{ .float = std.math.hypot(x, y) };
}

/// sign(x): -1, 0 or 1, an int for an int.
fn mathSign(th: *Thread, args: []Value) Error!Value {
    const x = api.arg(args, 0);
    return switch (x) {
        .int => |i| .{ .int = std.math.sign(i) },
        .float => |f| .{ .float = if (std.math.isNan(f)) f else std.math.sign(f) },
        else => th.vm.raise("sign: a number expected, got {s}", .{x.typeName()}),
    };
}

/// clamp(x, lo, hi): x limited to lo..hi; ints stay ints.
fn mathClamp(th: *Thread, args: []Value) Error!Value {
    const x = api.arg(args, 0);
    const lo = api.arg(args, 1);
    const hi = api.arg(args, 2);
    if (x == .int and lo == .int and hi == .int) return .{ .int = std.math.clamp(x.int, lo.int, @max(lo.int, hi.int)) };
    const xf = try api.argNumber(th, args, 0, "x");
    const lof = try api.argNumber(th, args, 1, "lo");
    const hif = try api.argNumber(th, args, 2, "hi");
    return .{ .float = @min(@max(xf, lof), @max(lof, hif)) };
}

/// lerp(a, b, t): a + (b - a) * t.
fn mathLerp(th: *Thread, args: []Value) Error!Value {
    const a = try api.argNumber(th, args, 0, "a");
    const b = try api.argNumber(th, args, 1, "b");
    const t = try api.argNumber(th, args, 2, "t");
    return .{ .float = a + (b - a) * t };
}

fn mathIsNan(th: *Thread, args: []Value) Error!Value {
    _ = th;
    const x = api.arg(args, 0);
    return .{ .bool = x == .float and std.math.isNan(x.float) };
}

fn mathIsInf(th: *Thread, args: []Value) Error!Value {
    _ = th;
    const x = api.arg(args, 0);
    return .{ .bool = x == .float and std.math.isInf(x.float) };
}

/// random_int(lo, hi): a random int from lo up to and including hi.
fn mathRandomInt(th: *Thread, args: []Value) Error!Value {
    ensurePrng(th);
    const lo = try api.argInt(th, args, 0, "lo");
    const hi = try api.argInt(th, args, 1, "hi");
    if (hi < lo) return th.vm.raise("random_int: hi ({d}) is below lo ({d})", .{ hi, lo });
    return .{ .int = prng.random().intRangeAtMost(i64, lo, hi) };
}

/// seed(n): makes random and random_int repeat the same sequence for n.
fn mathSeed(th: *Thread, args: []Value) Error!Value {
    const n = try api.argInt(th, args, 0, "n");
    prng = std.Random.DefaultPrng.init(@bitCast(n));
    prng_ready = true;
    return .null;
}
