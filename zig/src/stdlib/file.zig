//! The file userdata behind open(): a libc FILE with read/write/readBytes/
//! writeBytes/close methods.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

const FILE = opaque {};
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fread(buf: [*]u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fwrite(buf: [*]const u8, size: usize, n: usize, f: *FILE) usize;
extern "c" fn fflush(f: *FILE) c_int;
extern "c" fn ferror(f: *FILE) c_int;

pub const tname = "file";

const Handle = struct {
    vm: *VM,
    file: ?*FILE,
    path: []u8,
};

var file_meta: ?*Table = null;

pub fn init(vm: *VM) void {
    const meta = vm.newTable(0, 2);
    meta.set(vm.gpa, vm.str("__index"), .{ .table = stdlib.makeModule(vm, &.{
        .{ .name = "read", .f = fileRead },
        .{ .name = "write", .f = fileWrite },
        .{ .name = "readBytes", .f = fileReadBytes },
        .{ .name = "writeBytes", .f = fileWriteBytes },
        .{ .name = "close", .f = fileClose },
    }) });
    meta.set(vm.gpa, vm.str("__type"), vm.str("file"));
    file_meta = meta;
    // keep the metatable alive
    vm.registry.set(vm.gpa, vm.str("file_meta"), .{ .table = meta });
}

fn finalize(data: ?*anyopaque) callconv(.c) void {
    const h: *Handle = @ptrCast(@alignCast(data.?));
    if (h.file) |f| _ = fclose(f);
    h.vm.gpa.free(h.path);
}

fn toString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("File: '{s}'", .{u.as(Handle).path});
}

pub fn coreOpen(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const mode = api.argStringOr(args, 1, "r");
    const r = std.mem.indexOfScalar(u8, mode, 'r') != null;
    const w = std.mem.indexOfScalar(u8, mode, 'w') != null;
    const a = std.mem.indexOfScalar(u8, mode, 'a') != null;
    var cmode: [*:0]const u8 = "rb";
    if (r and w) cmode = "w+b" else if (w) cmode = "wb";
    if (a) cmode = if (w and !r) "ab" else "a+b";

    const pathz = vm.gpa.allocSentinel(u8, path.len, 0) catch oom();
    @memcpy(pathz, path);
    defer vm.gpa.free(pathz);
    // like the Go VM: create the file (and its directory) if it is missing
    const cwd = std.Io.Dir.cwd();
    _ = cwd.statFile(vm.io, path, .{}) catch {
        if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(vm.io, dir) catch {};
        if (cwd.createFile(vm.io, path, .{})) |f| f.close(vm.io) else |_| {}
    };
    const f = fopen(pathz, cmode) orelse return vm.raise("cannot open {s}", .{path});
    const u = vm.newUserdataOf(Handle, .{ .vm = vm, .file = f, .path = vm.gpa.dupe(u8, path) catch oom() }, tname, file_meta);
    u.finalizer = finalize;
    u.to_string = toString;
    return .{ .userdata = u };
}

fn handle(th: *Thread, args: []Value) Error!*Handle {
    return api.argUserdata(th, args, 0, "file", Handle, tname);
}

fn readN(th: *Thread, args: []Value) Error![]u8 {
    const vm = th.vm;
    const h = try handle(th, args);
    const f = h.file orelse return vm.raise("file {s} is closed", .{h.path});
    const n = api.argIntOr(args, 1, -1);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(vm.gpa);
    if (n < 0) {
        var chunk: [1 << 16]u8 = undefined;
        while (true) {
            const k = fread(&chunk, 1, chunk.len, f);
            buf.appendSlice(vm.gpa, chunk[0..k]) catch oom();
            if (k < chunk.len) break;
        }
    } else {
        buf.resize(vm.gpa, @intCast(n)) catch oom();
        const k = fread(buf.items.ptr, 1, buf.items.len, f);
        buf.shrinkRetainingCapacity(k);
    }
    if (ferror(f) != 0) return vm.raise("read error on {s}", .{h.path});
    return buf.toOwnedSlice(vm.gpa) catch oom();
}

fn fileRead(th: *Thread, args: []Value) Error!Value {
    const buf = try readN(th, args);
    defer th.vm.gpa.free(buf);
    return th.vm.str(buf);
}

fn fileReadBytes(th: *Thread, args: []Value) Error!Value {
    const buf = try readN(th, args);
    defer th.vm.gpa.free(buf);
    const t = th.vm.newTable(buf.len, 0);
    for (buf) |b| t.append(th.vm.gpa, .{ .int = b });
    return .{ .table = t };
}

fn fileWrite(th: *Thread, args: []Value) Error!Value {
    const h = try handle(th, args);
    const s = try api.argString(th, args, 1, "str");
    const f = h.file orelse return th.vm.raise("file {s} is closed", .{h.path});
    if (fwrite(s.ptr, 1, s.len, f) != s.len) return th.vm.raise("write error on {s}", .{h.path});
    return .null;
}

fn fileWriteBytes(th: *Thread, args: []Value) Error!Value {
    const h = try handle(th, args);
    const t = try api.argTable(th, args, 1, "bytes");
    const f = h.file orelse return th.vm.raise("file {s} is closed", .{h.path});
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(th.vm.gpa);
    var it = t.iterator();
    while (it.next()) |e| buf.append(th.vm.gpa, @truncate(@as(u64, @bitCast(e.val.asInt())))) catch oom();
    if (fwrite(buf.items.ptr, 1, buf.items.len, f) != buf.items.len) return th.vm.raise("write error on {s}", .{h.path});
    return .null;
}

fn fileClose(th: *Thread, args: []Value) Error!Value {
    const h = try handle(th, args);
    if (h.file) |f| {
        _ = fclose(f);
        h.file = null;
    }
    return .null;
}
