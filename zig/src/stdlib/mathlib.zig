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
        .{ .name = "round", .f = unary(roundHalfAway) },
        .{ .name = "floor", .f = unary(m_floor) },
        .{ .name = "ceil", .f = unary(m_ceil) },
        .{ .name = "abs", .f = mathAbs },
        .{ .name = "min", .f = mathMin },
        .{ .name = "max", .f = mathMax },
        .{ .name = "sqrt", .f = unary(m_sqrt) },
        .{ .name = "sin", .f = unary(m_sin) },
        .{ .name = "cos", .f = unary(m_cos) },
        .{ .name = "tan", .f = unary(m_tan) },
        .{ .name = "asin", .f = unary(m_asin) },
        .{ .name = "acos", .f = unary(m_acos) },
        .{ .name = "atan", .f = unary(m_atan) },
        .{ .name = "atan2", .f = mathAtan2 },
        .{ .name = "log", .f = unary(logE) },
        .{ .name = "exp", .f = unary(m_exp) },
    });
    t.set(vm.gpa, vm.str("pi"), .{ .float = std.math.pi });
    t.set(vm.gpa, vm.str("e"), .{ .float = std.math.e });
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

fn mathRandom(th: *Thread, args: []Value) Error!Value {
    if (!prng_ready) {
        var seed: [8]u8 = undefined;
        th.vm.io.random(&seed);
        prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
        prng_ready = true;
    }
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
