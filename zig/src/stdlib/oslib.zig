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
const bundle = @import("../bundle/exe.zig");
const bundlelib = @import("bundlelib.zig");

/// slang/os: files and process environment.
pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        // files
        .{ .name = "open", .f = @import("file.zig").osOpen },
        .{ .name = "exists", .f = osExists },
        .{ .name = "is_dir", .f = osIsDir },
        .{ .name = "stat", .f = osStat },
        .{ .name = "read_file", .f = osReadFile },
        .{ .name = "write_file", .f = osWriteFile },
        .{ .name = "append_file", .f = osAppendFile },
        .{ .name = "list_dir", .f = osListDir },
        .{ .name = "mkdir_all", .f = osMkdirAll },
        .{ .name = "remove", .f = osRemove },
        .{ .name = "remove_all", .f = osRemoveAll },
        .{ .name = "rename", .f = osRename },
        .{ .name = "copy_file", .f = osCopyFile },
        .{ .name = "temp_dir", .f = osTempDir },
        // the process
        .{ .name = "read_line", .f = osReadLine },
        .{ .name = "write_stderr", .f = osWriteStderr },
        .{ .name = "getenv", .f = osGetenv },
        .{ .name = "cwd", .f = osCwd },
        .{ .name = "executable", .f = osExecutable },
        .{ .name = "platform", .f = osPlatform },
        .{ .name = "cpu_count", .f = @import("isolatelib.zig").isoCpuCount },
        .{ .name = "exec", .f = osExec },
        .{ .name = "exit", .f = osExit },
    });
}

/// exec(argv, [cwd]) -> {status, stdout, stderr}: runs a program (argv[0],
/// looked up on the PATH) and waits for it; status is its exit code, -1 when
/// a signal ended it. Raises when the program cannot be started. Blocking:
/// for tools (slang get runs git with it); slang/async's exec is the
/// asynchronous one.
fn osExec(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const list = try api.argTable(th, args, 0, "argv");
    const n = list.arrayLen();
    if (n == 0) return vm.raise("exec: argv is empty", .{});
    var argv = vm.gpa.alloc([]const u8, n) catch oom();
    defer vm.gpa.free(argv);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        argv[i] = list.getInt(@intCast(i)).asBytes() orelse return vm.raise("exec: argv must hold strings", .{});
    }
    var cwd: std.process.Child.Cwd = .inherit;
    if (args.len > 1) {
        if (args[1].asBytes()) |dir| cwd = .{ .path = dir };
    }
    vm.flush();
    const r = std.process.run(vm.gpa, vm.io, .{ .argv = argv, .cwd = cwd }) catch |e| {
        return vm.raise("exec {s}: {t}", .{ argv[0], e });
    };
    defer vm.gpa.free(r.stdout);
    defer vm.gpa.free(r.stderr);
    const status: i64 = switch (r.term) {
        .exited => |code| code,
        else => -1,
    };
    const t = vm.newTable(0, 3);
    t.set(vm.gpa, vm.str("status"), .{ .int = status });
    t.set(vm.gpa, vm.str("stdout"), vm.str(r.stdout));
    t.set(vm.gpa, vm.str("stderr"), vm.str(r.stderr));
    return .{ .table = t };
}

/// mkdir_all(path): creates the directory and its parents.
fn osMkdirAll(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    std.Io.Dir.cwd().createDirPath(th.vm.io, path) catch |e| return th.vm.raise("cannot create {s}: {t}", .{ path, e });
    return .null;
}

// In a program built by slang build, a relative path that names a bundled
// file or directory is the bundle's for exists, is_dir, read_file and
// list_dir (bundle.resolve); writes always go to the disk, so a program
// that writes over a bundled path still reads the bundled file.

fn osExists(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    if (bundle.resolve(path) != null) return .{ .bool = true };
    _ = std.Io.Dir.cwd().statFile(th.vm.io, path, .{}) catch return .{ .bool = false };
    return .{ .bool = true };
}

fn osIsDir(th: *Thread, args: []Value) Error!Value {
    const path = try api.argString(th, args, 0, "path");
    if (bundle.resolve(path)) |h| return .{ .bool = h == .dir };
    const st = std.Io.Dir.cwd().statFile(th.vm.io, path, .{}) catch return .{ .bool = false };
    return .{ .bool = st.kind == .directory };
}

fn osReadFile(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    if (bundle.resolve(path)) |h| switch (h) {
        .file => |e| return bundlelib.readEntry(vm, e),
        .dir => {},
    };
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

fn osAppendFile(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const content = try api.argString(th, args, 1, "content");
    const cwd = std.Io.Dir.cwd();
    const f = cwd.openFile(vm.io, path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => cwd.createFile(vm.io, path, .{}) catch |e2| return vm.raise("cannot write {s}: {t}", .{ path, e2 }),
        else => return vm.raise("cannot write {s}: {t}", .{ path, e }),
    };
    defer f.close(vm.io);
    const st = f.stat(vm.io) catch |e| return vm.raise("cannot write {s}: {t}", .{ path, e });
    f.writePositionalAll(vm.io, content, st.size) catch |e| return vm.raise("cannot write {s}: {t}", .{ path, e });
    return .null;
}

/// stat(path) -> {size, mtime, is_dir, mode} or null when nothing is there
/// (mtime in milliseconds since the epoch).
fn osStat(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    if (bundle.resolve(path)) |h| {
        const t = vm.newTable(0, 4);
        switch (h) {
            .file => |e| t.set(vm.gpa, vm.str("size"), .{ .int = @intCast(e.raw_len) }),
            .dir => t.set(vm.gpa, vm.str("size"), .{ .int = 0 }),
        }
        t.set(vm.gpa, vm.str("mtime"), .{ .int = 0 });
        t.set(vm.gpa, vm.str("is_dir"), .{ .bool = h == .dir });
        t.set(vm.gpa, vm.str("mode"), .{ .int = if (h == .dir) 0o555 else 0o444 });
        return .{ .table = t };
    }
    const st = std.Io.Dir.cwd().statFile(vm.io, path, .{}) catch return .null;
    const t = vm.newTable(0, 4);
    t.set(vm.gpa, vm.str("size"), .{ .int = @intCast(st.size) });
    t.set(vm.gpa, vm.str("mtime"), .{ .int = @intCast(@divFloor(st.mtime.nanoseconds, 1_000_000)) });
    t.set(vm.gpa, vm.str("is_dir"), .{ .bool = st.kind == .directory });
    const mode: i64 = if (@hasDecl(@TypeOf(st.permissions), "toMode")) @intCast(st.permissions.toMode() & 0o7777) else 0;
    t.set(vm.gpa, vm.str("mode"), .{ .int = mode });
    return .{ .table = t };
}

/// remove(path): deletes a file or an empty directory.
fn osRemove(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(vm.io, path) catch |e| switch (e) {
        error.IsDir => cwd.deleteDir(vm.io, path) catch |e2| return vm.raise("cannot remove {s}: {t}", .{ path, e2 }),
        else => return vm.raise("cannot remove {s}: {t}", .{ path, e }),
    };
    return .null;
}

/// remove_all(path): deletes path and everything under it; nothing there is
/// not an error.
fn osRemoveAll(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    std.Io.Dir.cwd().deleteTree(vm.io, path) catch |e| return vm.raise("cannot remove {s}: {t}", .{ path, e });
    return .null;
}

/// temp_dir(): the directory for temporary files (TMPDIR, else /tmp).
fn osTempDir(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const dir = th.vm.getenv("TMPDIR") orelse th.vm.getenv("TEMP") orelse "/tmp";
    const trimmed = if (dir.len > 1) std.mem.trimEnd(u8, dir, "/") else dir;
    return th.vm.str(trimmed);
}

/// read_line(): the next line of standard input without its line ending,
/// or null at the end.
fn osReadLine(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    vm.flush();
    const line = vm.stdin.interface.takeDelimiter('\n') catch return .null;
    const l = line orelse return .null;
    return vm.str(std.mem.trimEnd(u8, l, "\r\n"));
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
    if (bundle.resolve(path)) |h| if (h == .dir) return listBundledDir(vm, path);
    const names = listDir(vm, path) catch |e| return vm.raise("cannot list {s}: {t}", .{ path, e });
    defer freeNames(vm, names);
    const t = vm.newTable(names.len, 0);
    for (names) |n| t.append(vm.gpa, vm.str(n));
    return .{ .table = t };
}

/// A bundled directory's names merged with the disk's, if it exists there.
fn listBundledDir(vm: *VM, path: []const u8) Value {
    var all: std.ArrayList([]const u8) = .empty;
    defer all.deinit(vm.gpa);
    _ = bundle.current.?.list(vm.gpa, path, &all) catch oom();
    const disk = listDir(vm, path) catch null;
    defer if (disk) |d| freeNames(vm, d);
    if (disk) |d| for (d) |n| all.append(vm.gpa, n) catch oom();
    std.mem.sort([]const u8, all.items, {}, lessThan);
    const t = vm.newTable(all.items.len, 0);
    for (all.items, 0..) |n, i| {
        if (i > 0 and std.mem.eql(u8, n, all.items[i - 1])) continue;
        t.append(vm.gpa, vm.str(n));
    }
    return .{ .table = t };
}

/// executable(): the path of the running executable.
fn osExecutable(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const path = std.process.executablePathAlloc(vm.io, vm.gpa) catch |e| return vm.raise("executable: {t}", .{e});
    defer vm.gpa.free(path);
    return vm.str(path);
}

/// rename(from, to): moves a file or directory, replacing to.
fn osRename(th: *Thread, args: []Value) Error!Value {
    const from = try api.argString(th, args, 0, "from");
    const to = try api.argString(th, args, 1, "to");
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, th.vm.io) catch |e| return th.vm.raise("cannot rename {s} to {s}: {t}", .{ from, to, e });
    return .null;
}

/// copy_file(from, to): copies a file, its permissions included (to is
/// replaced; its directory must exist).
fn osCopyFile(th: *Thread, args: []Value) Error!Value {
    const from = try api.argString(th, args, 0, "from");
    const to = try api.argString(th, args, 1, "to");
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(from, cwd, to, th.vm.io, .{}) catch |e| return th.vm.raise("cannot copy {s} to {s}: {t}", .{ from, to, e });
    return .null;
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

/// platform() -> "<os>-<arch>" of the running binary, as Zig names them
/// ("macos-aarch64", "linux-x86_64"): where packages keep native builds.
fn osPlatform(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const builtin = @import("builtin");
    return th.vm.str(@tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch));
}

fn osExit(th: *Thread, args: []Value) Error!Value {
    // what the end of a program does, since the VM is not destroyed: the
    // finalizers of what is still alive (vm.on_collect), the output, the
    // profile (slang run --profile)
    @import("../vm/gc.zig").finalizeAll(th.vm);
    th.vm.flush();
    if (th.vm.profiler) |p| p.finish();
    const code = api.argIntOr(args, 0, 0);
    if (th.vm.debugger) |d| d.finish(@truncate(@as(u64, @bitCast(code))));
    std.process.exit(@truncate(@as(u64, @bitCast(code))));
}
