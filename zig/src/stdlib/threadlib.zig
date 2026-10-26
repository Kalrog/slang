const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

/// slang/thread: cooperative coroutines.
pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "create", .f = thCreate },
        .{ .name = "resume", .f = thResume },
        .{ .name = "yield", .f = thYield },
        .{ .name = "state", .f = thState },
        .{ .name = "current", .f = thCurrent },
        .{ .name = "id", .f = thId },
    });
}

/// create(func): a new coroutine; it starts running on the first resume.
fn thCreate(th: *Thread, args: []Value) Error!Value {
    const cl = try api.argFunction(th, args, 0, "function");
    return .{ .thread = th.vm.newThread(cl) };
}

/// resume(thread, [value]): run the coroutine until it yields or returns and
/// return the yielded value or result. On the first resume the value is
/// passed as the function argument, later it is returned by yield.
fn thResume(th: *Thread, args: []Value) Error!Value {
    const co = try api.argThread(th, args, 0, "thread");
    const rest = th.vm.gpa.dupe(Value, args[1..]) catch oom();
    defer th.vm.gpa.free(rest);
    return co.resumeCo(rest);
}

/// yield([value]): suspend the current coroutine.
fn thYield(th: *Thread, args: []Value) Error!Value {
    const v: Value = if (args.len > 0) args[args.len - 1] else .null;
    return th.yield(v);
}

/// state([thread]): "init", "running", "suspended" or "dead".
fn thState(th: *Thread, args: []Value) Error!Value {
    var target = th;
    if (args.len > 0) target = try api.argThread(th, args, 0, "thread");
    return th.vm.str(target.status.name());
}

fn thCurrent(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .thread = th };
}

fn thId(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .int = th.id };
}
