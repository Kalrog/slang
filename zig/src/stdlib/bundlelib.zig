//! slang/bundle: the files a program built by `slang build` carries (its
//! payload, see bundle/format.zig), and slang/bundle_tool, the part of
//! `slang build` that writes executables.
//!
//! Paths are relative, '/'-separated, as the project had them. slang/os
//! reads bundled files transparently (os.read_file, exists, is_dir,
//! list_dir); this module is for what os cannot say: whether a file is
//! bundled, its stored form, its build-time stat.

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
const format = @import("../bundle/format.zig");
const exe = @import("../bundle/exe.zig");

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "active", .f = bActive },
        .{ .name = "exists", .f = bExists },
        .{ .name = "is_dir", .f = bIsDir },
        .{ .name = "read", .f = bRead },
        .{ .name = "read_raw", .f = bReadRaw },
        .{ .name = "stat", .f = bStat },
        .{ .name = "list", .f = bList },
        .{ .name = "files", .f = bFiles },
        .{ .name = "module", .f = bModule },
        .{ .name = "dir", .f = bDir },
    });
}

pub fn toolModule(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "write_executable", .f = toolWriteExecutable },
        .{ .name = "inspect", .f = toolInspect },
    });
}

fn hit(th: *Thread, args: []Value) Error!?exe.Bundle.Hit {
    return exe.resolve(try api.argString(th, args, 0, "path"));
}

/// active(): whether this program runs from a built executable.
fn bActive(th: *Thread, args: []Value) Error!Value {
    _ = th;
    _ = args;
    return .{ .bool = exe.current != null };
}

/// exists(path): whether path is a bundled file or a directory of them.
fn bExists(th: *Thread, args: []Value) Error!Value {
    return .{ .bool = try hit(th, args) != null };
}

/// is_dir(path): whether bundled files lie under path.
fn bIsDir(th: *Thread, args: []Value) Error!Value {
    const h = try hit(th, args) orelse return .{ .bool = false };
    return .{ .bool = h == .dir };
}

/// read(path): the contents of a bundled file (uncompressed), or null when
/// the bundle has no such file.
fn bRead(th: *Thread, args: []Value) Error!Value {
    const h = try hit(th, args) orelse return .null;
    return switch (h) {
        .file => |e| readEntry(th.vm, e),
        .dir => .null,
    };
}

pub fn readEntry(vm: *VM, e: format.Entry) Error!Value {
    const data = exe.current.?.read(vm.gpa, vm.io, e) catch |err| {
        return vm.raise("cannot read bundled file {s}: {t}", .{ e.name, err });
    };
    defer vm.gpa.free(data);
    return vm.str(data);
}

/// read_raw(path): {data, encoding} as stored ("gzip" or null), or null; for
/// a file kept next to the executable (--dir) {path} instead.
fn bReadRaw(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const h = try hit(th, args) orelse return .null;
    const e = switch (h) {
        .file => |e| e,
        .dir => return .null,
    };
    const t = vm.newTable(0, 2);
    if (e.external()) {
        try setDiskPath(vm, t, e);
    } else {
        t.set(vm.gpa, vm.str("data"), vm.str(e.data));
        t.set(vm.gpa, vm.str("encoding"), encodingValue(vm, e));
    }
    return .{ .table = t };
}

fn encodingValue(vm: *VM, e: format.Entry) Value {
    return if (e.encoding == .gzip) vm.str("gzip") else .null;
}

fn setDiskPath(vm: *VM, t: *Table, e: format.Entry) Error!void {
    const path = exe.current.?.diskPath(vm.gpa, e) catch oom();
    defer vm.gpa.free(path);
    t.set(vm.gpa, vm.str("path"), vm.str(path));
}

/// stat(path): {is_file, is_dir, size, stored_size, mtime, encoding, path}
/// of a bundled file or directory, or null. size is the file's own length,
/// stored_size what the bundle holds; mtime is the source file's
/// (milliseconds)
/// at build time; path is set for a file kept next to the executable.
fn bStat(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const h = try hit(th, args) orelse return .null;
    const t = vm.newTable(0, 7);
    switch (h) {
        .dir => {
            t.set(vm.gpa, vm.str("is_file"), .{ .bool = false });
            t.set(vm.gpa, vm.str("is_dir"), .{ .bool = true });
        },
        .file => |e| {
            t.set(vm.gpa, vm.str("is_file"), .{ .bool = true });
            t.set(vm.gpa, vm.str("is_dir"), .{ .bool = false });
            t.set(vm.gpa, vm.str("size"), .{ .int = @intCast(e.raw_len) });
            t.set(vm.gpa, vm.str("stored_size"), .{ .int = @intCast(e.data.len) });
            t.set(vm.gpa, vm.str("mtime"), .{ .int = @as(i64, e.mtime) * 1000 });
            t.set(vm.gpa, vm.str("encoding"), encodingValue(vm, e));
            if (e.external()) try setDiskPath(vm, t, e);
        },
    }
    return .{ .table = t };
}

/// list(path): the sorted names of the bundled files and directories
/// directly under path, or null when it is not a bundled directory.
fn bList(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const b = exe.current orelse return .null;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(vm.gpa);
    if (!(b.list(vm.gpa, path, &names) catch oom())) return .null;
    const t = vm.newTable(names.items.len, 0);
    for (names.items) |name| t.append(vm.gpa, vm.str(name));
    return .{ .table = t };
}

/// files(): the names of all bundled files, sorted.
fn bFiles(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const t = vm.newTable(0, 0);
    const b = exe.current orelse return .{ .table = t };
    for (0..b.index.count) |i| {
        const e = b.index.entry(i);
        if (e.kind == .asset) t.append(vm.gpa, vm.str(e.name));
    }
    return .{ .table = t };
}

/// module(name): the bundled module's function (not yet run), or null.
fn bModule(th: *Thread, args: []Value) Error!Value {
    const name = try api.argString(th, args, 0, "name");
    const b = exe.current orelse return .null;
    const e = b.index.lookup(.module, name) orelse return .null;
    return .{ .function = try th.vm.loadBytes(e.data) };
}

/// dir(): the directory of the running executable when bundled, else null.
fn bDir(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const b = exe.current orelse return .null;
    return th.vm.str(b.exe_dir);
}

fn kindOf(th: *Thread, t: *Table) Error!format.Kind {
    const k = t.getName("kind").asBytes() orelse return th.vm.raise("bundle entry without kind", .{});
    return std.meta.stringToEnum(format.Kind, k) orelse th.vm.raise("unknown bundle entry kind {s}", .{k});
}

/// write_executable(base, out, entries, [options]) -> {{kind, name, size,
/// stored_size, encoding}}: writes out, the executable base (a slang
/// runtime) with a payload of entries, executable and on macOS signed.
/// An entry is {kind: "module"|"asset", name, data} or {kind, name, file}
/// (read here; its mtime is kept), with compress = true to gzip it when
/// that saves 10% and external = true for a file that stays next to the
/// executable. options: {sign: "adhoc" (default) | "external"} (external
/// leaves a Mach-O unsigned for `codesign`), identifier (default: the
/// name of out). out is replaced, never rewritten in place.
fn toolWriteExecutable(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const gpa = vm.gpa;
    const base_path = try api.argString(th, args, 0, "base");
    const out_path = try api.argString(th, args, 1, "out");
    const entries = try api.argTable(th, args, 2, "entries");
    const options = api.arg(args, 3).asTable();
    var signing: exe.Signing = .adhoc;
    var identifier = std.fs.path.basename(out_path);
    if (options) |o| {
        if (o.getName("sign").asBytes()) |s| {
            if (std.mem.eql(u8, s, "external")) signing = .external else if (!std.mem.eql(u8, s, "adhoc")) {
                return vm.raise("write_executable: sign must be \"adhoc\" or \"external\"", .{});
            }
        }
        if (o.getName("identifier").asBytes()) |id| identifier = id;
    }

    var w = format.Writer.init(gpa);
    defer w.deinit();
    const report = vm.newTable(entries.arrayLen(), 0);
    for (0..entries.arrayLen()) |i| {
        const t = entries.getInt(@intCast(i)).asTable() orelse return vm.raise("write_executable: entries must be tables", .{});
        const kind = try kindOf(th, t);
        const name = t.getName("name").asBytes() orelse return vm.raise("write_executable: entry without name", .{});
        var opts: format.AddOptions = .{
            .compress = t.getName("compress").truthy(),
            .external = t.getName("external").truthy(),
        };
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);
        const data = if (t.getName("data").asBytes()) |d| d else blk: {
            const file = t.getName("file").asBytes() orelse return vm.raise("write_executable: entry {s} has neither data nor file", .{name});
            const st = std.Io.Dir.cwd().statFile(vm.io, file, .{}) catch |e| return vm.raise("cannot read {s}: {t}", .{ file, e });
            opts.mtime = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
            owned = std.Io.Dir.cwd().readFileAlloc(vm.io, file, gpa, .unlimited) catch |e| return vm.raise("cannot read {s}: {t}", .{ file, e });
            break :blk owned.?;
        };
        const e = w.add(kind, name, data, opts) catch |err| return vm.raise("bundle entry {s}: {t}", .{ name, err });
        report.append(gpa, entryInfo(vm, e));
    }
    const payload = w.finish() catch oom();
    defer gpa.free(payload);

    const base = std.Io.Dir.cwd().readFileAlloc(vm.io, base_path, gpa, .unlimited) catch |e| return vm.raise("cannot read {s}: {t}", .{ base_path, e });
    defer gpa.free(base);
    const image = exe.assemble(gpa, base, payload, identifier, signing) catch |e| return vm.raise("cannot build an executable from {s}: {t}", .{ base_path, e });
    defer gpa.free(image);

    const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{out_path}) catch oom();
    defer gpa.free(tmp);
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(vm.io, .{ .sub_path = tmp, .data = image }) catch |e| return vm.raise("cannot write {s}: {t}", .{ tmp, e });
    cwd.setFilePermissions(vm.io, tmp, .fromMode(0o755), .{}) catch |e| return vm.raise("cannot make {s} executable: {t}", .{ tmp, e });
    // a new file, not new contents: macOS caches signatures per file
    cwd.rename(tmp, cwd, out_path, vm.io) catch |e| return vm.raise("cannot write {s}: {t}", .{ out_path, e });
    return .{ .table = report };
}

fn entryInfo(vm: *VM, e: format.Entry) Value {
    const t = vm.newTable(0, 6);
    t.set(vm.gpa, vm.str("kind"), vm.str(@tagName(e.kind)));
    t.set(vm.gpa, vm.str("name"), vm.str(e.name));
    t.set(vm.gpa, vm.str("size"), .{ .int = @intCast(e.raw_len) });
    t.set(vm.gpa, vm.str("stored_size"), .{ .int = @intCast(e.data.len) });
    t.set(vm.gpa, vm.str("encoding"), encodingValue(vm, e));
    t.set(vm.gpa, vm.str("external"), .{ .bool = e.external() });
    return .{ .table = t };
}

/// inspect(path) -> {{kind, name, size, stored_size, encoding, external}}:
/// the entries of a built executable, or null when it has no bundle.
fn toolInspect(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const image = std.Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |e| return vm.raise("cannot read {s}: {t}", .{ path, e });
    defer vm.gpa.free(image);
    const payload = exe.find(image) orelse return .null;
    const idx = format.Index.parse(payload) catch |e| return vm.raise("{s}: damaged bundle: {t}", .{ path, e });
    const t = vm.newTable(idx.count, 0);
    for (0..idx.count) |i| t.append(vm.gpa, entryInfo(vm, idx.entry(i)));
    return .{ .table = t };
}
