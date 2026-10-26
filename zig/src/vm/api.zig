//! Helpers for native functions written in Zig: argument access with the
//! same error messages as the Go VM ("Expected int for x got string").

const std = @import("std");
const root = @import("../vm.zig");
const Value = root.Value;
const Thread = root.Thread;
const Table = root.Table;
const Closure = root.Closure;
const Userdata = root.Userdata;
const Error = root.Error;

pub fn arg(args: []Value, i: usize) Value {
    return if (i < args.len) args[i] else .null;
}

pub fn argError(th: *Thread, name: []const u8, i: usize, want: []const u8, got: Value) Error {
    if (name.len == 0) return th.vm.raise("Expected {s} for {d} got {s}", .{ want, i, got.typeName() });
    return th.vm.raise("Expected {s} for {s} got {s}", .{ want, name, got.typeName() });
}

pub fn argString(th: *Thread, args: []Value, i: usize, name: []const u8) Error![]const u8 {
    const v = arg(args, i);
    return v.asBytes() orelse argError(th, name, i, "String", v);
}

pub fn argStringOr(args: []Value, i: usize, def: []const u8) []const u8 {
    return arg(args, i).asBytes() orelse def;
}

pub fn argInt(th: *Thread, args: []Value, i: usize, name: []const u8) Error!i64 {
    const v = arg(args, i);
    return switch (v) {
        .int => |n| n,
        else => argError(th, name, i, "int", v),
    };
}

pub fn argIntOr(args: []Value, i: usize, def: i64) i64 {
    return switch (arg(args, i)) {
        .int => |n| n,
        else => def,
    };
}

pub fn argNumber(th: *Thread, args: []Value, i: usize, name: []const u8) Error!f64 {
    const v = arg(args, i);
    if (!v.isNumber()) return argError(th, name, i, "num", v);
    return v.asNumber();
}

pub fn argNumberOr(args: []Value, i: usize, def: f64) f64 {
    const v = arg(args, i);
    return if (v.isNumber()) v.asNumber() else def;
}

/// Truthiness of args[i]; missing arguments count as def.
pub fn argBool(args: []Value, i: usize, def: bool) bool {
    if (i >= args.len or args[i] == .null) return def;
    return args[i].truthy();
}

pub fn argTable(th: *Thread, args: []Value, i: usize, name: []const u8) Error!*Table {
    const v = arg(args, i);
    return v.asTable() orelse argError(th, name, i, "SlangTable", v);
}

pub fn argFunction(th: *Thread, args: []Value, i: usize, name: []const u8) Error!*Closure {
    const v = arg(args, i);
    return v.asClosure() orelse argError(th, name, i, "Closure", v);
}

pub fn argThread(th: *Thread, args: []Value, i: usize, name: []const u8) Error!*Thread {
    const v = arg(args, i);
    return v.asThread() orelse argError(th, name, i, "Thread", v);
}

/// The data of args[i] if it is a userdata of the named type.
pub fn argUserdata(th: *Thread, args: []Value, i: usize, name: []const u8, comptime T: type, tname: []const u8) Error!*T {
    const v = arg(args, i);
    const u = v.asUserdata() orelse return argError(th, name, i, "userdata", v);
    if (!std.mem.eql(u8, u.tname, tname)) {
        return th.vm.raise("Expected {s} for {s} got {s}", .{ tname, name, u.tname });
    }
    return u.as(T);
}
