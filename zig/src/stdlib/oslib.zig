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

var process_start: ?std.Io.Timestamp = null;

/// slang/os: files and process environment.
pub fn module(vm: *VM) *Table {
    process_start = std.Io.Clock.now(.awake, vm.io);
    return stdlib.makeModule(vm, &.{
        .{ .name = "exists", .f = osExists },
        .{ .name = "is_dir", .f = osIsDir },
        .{ .name = "read_file", .f = osReadFile },
        .{ .name = "write_file", .f = osWriteFile },
        .{ .name = "write_stderr", .f = osWriteStderr },
        .{ .name = "list_dir", .f = osListDir },
        .{ .name = "getenv", .f = osGetenv },
        .{ .name = "cwd", .f = osCwd },
        .{ .name = "exit", .f = osExit },
        .{ .name = "clock", .f = osClock },
        .{ .name = "mkdir_all", .f = osMkdirAll },
        .{ .name = "time_ms", .f = osTimeMs },
    });
}

/// mkdir_all(path): creates the directory and its parents.
fn osMkdirAll(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    std.Io.Dir.cwd().createDirPath(th.vm.io, path) catch |e| return th.vm.raise("cannot create {s}: {t}", .{ path, e });
    return .null;
}

/// clock(): seconds since program start (monotonic, double).
fn osClock(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const now = std.Io.Clock.now(.awake, th.vm.io);
    const ns = process_start.?.durationTo(now).nanoseconds;
    return .{ .float = @as(f64, @floatFromInt(ns)) / 1e9 };
}

/// time_ms(): milliseconds since the Unix epoch (int).
fn osTimeMs(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const now = std.Io.Clock.now(.real, th.vm.io);
    return .{ .int = @intCast(@divTrunc(now.nanoseconds, 1_000_000)) };
}

fn osExists(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    _ = std.Io.Dir.cwd().statFile(th.vm.io, path, .{}) catch return .{ .bool = false };
    return .{ .bool = true };
}

fn osIsDir(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    const st = std.Io.Dir.cwd().statFile(th.vm.io, path, .{}) catch return .{ .bool = false };
    return .{ .bool = st.kind == .directory };
}

fn osReadFile(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const data = std.Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |e| {
        return vm.raise("cannot read {s}: {t}", .{ path, e });
    };
    defer vm.gpa.free(data);
    return vm.str(data);
}

fn osWriteFile(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    const content = try api.argString(th, args, 1, "content");
    std.Io.Dir.cwd().writeFile(th.vm.io, .{ .sub_path = path, .data = content }) catch |e| {
        return th.vm.raise("cannot write {s}: {t}", .{ path, e });
    };
    return .null;
}

/// write_stderr(text): writes text to the standard error stream.
fn osWriteStderr(th: *Thread, args: []Value) Error!Value {
    const text = try api.argString(th, args, 0, "text");
    th.vm.flush();
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(th.vm.io, &buf);
    w.interface.writeAll(text) catch {};
    w.interface.flush() catch {};
    return .null;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The sorted names of the entries of a directory (like Go's os.ReadDir).
pub fn listDir(vm: *VM, path: []const u8) ![][]u8 {
    var dir = try std.Io.Dir.cwd().openDir(vm.io, path, .{ .iterate = true });
    defer dir.close(vm.io);
    var names: std.ArrayList([]u8) = .empty;
    var it = dir.iterate();
    while (try it.next(vm.io)) |e| {
        names.append(vm.gpa, vm.gpa.dupe(u8, e.name) catch oom()) catch oom();
    }
    std.mem.sort([]u8, names.items, {}, lessThan);
    return names.toOwnedSlice(vm.gpa) catch oom();
}

pub fn freeNames(vm: *VM, names: [][]u8) void {
    for (names) |n| vm.gpa.free(n);
    vm.gpa.free(names);
}

fn osListDir(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const names = listDir(vm, path) catch |e| return vm.raise("cannot list {s}: {t}", .{ path, e });
    defer freeNames(vm, names);
    const t = vm.newTable(names.len, 0);
    for (names) |n| t.append(vm.gpa, vm.str(n));
    return .{ .table = t };
}

fn osGetenv(th: *Thread, args: []Value) Error!Value {
    const name = try api.argString(th, args, 0, "name");
    const val = th.vm.getenv(name) orelse return .null;
    return th.vm.str(val);
}

fn osCwd(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const dir = std.process.currentPathAlloc(th.vm.io, th.vm.gpa) catch |e| return th.vm.raise("cwd: {t}", .{e});
    defer th.vm.gpa.free(dir);
    return th.vm.str(dir);
}

fn osExit(th: *Thread, args: []Value) Error!Value {
    th.vm.flush();
    const code = api.argIntOr(args, 0, 0);
    std.process.exit(@truncate(@as(u64, @bitCast(code))));
}
