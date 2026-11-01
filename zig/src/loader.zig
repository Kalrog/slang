//! Loading of native extensions: shared libraries that export
//! slang_open_<name> (see include/slang.h). vm.load_native(name) is called
//! by the native loader in slang/package.

const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const capi = @import("capi.zig");

const extensions: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{".dll"},
    .macos, .ios => &.{ ".dylib", ".so" },
    else => &.{".so"},
};

/// The module name with '/', '-' and '.' replaced by '_' (the suffix of
/// the entry point symbols).
fn mangle(gpa: std.mem.Allocator, name: []const u8) []u8 {
    const out = gpa.dupe(u8, name) catch oom();
    for (out) |*c| {
        if (c.* == '/' or c.* == '-' or c.* == '.') c.* = '_';
    }
    return out;
}

/// Looks for <path>/<name>.<ext> or <path>/lib<name>.<ext> in every native
/// search path; returns the first file that exists.
fn findLibrary(vm: *VM, name: []const u8) ?[]u8 {
    const paths = vm.packages.getName("native_search_paths").asTable() orelse return null;
    var it = paths.iterator();
    while (it.next()) |e| {
        const dir = e.val.asBytes() orelse continue;
        for (extensions) |ext| {
            for ([_][]const u8{ "", "lib" }) |prefix| {
                const file = std.fmt.allocPrint(vm.gpa, "{s}/{s}{s}{s}", .{ dir, prefix, name, ext }) catch oom();
                if (std.Io.Dir.cwd().statFile(vm.io, file, .{})) |_| {
                    return file;
                } else |_| {}
                vm.gpa.free(file);
            }
        }
    }
    return null;
}

/// The entry points of an extension linked into the executable itself (by
/// slang build), or null. (On macOS the search also sees extensions already
/// loaded from a library, which is the same extension.)
fn selfLookup(version_sym: [:0]const u8, open_sym: [:0]const u8) ?struct { version: *const fn () callconv(.c) c_int, open: capi.CFunction } {
    const self = std.c.dlopen(null, .{ .LAZY = true }) orelse return null;
    const version = std.c.dlsym(self, version_sym) orelse return null;
    const open = std.c.dlsym(self, open_sym) orelse return null;
    return .{ .version = @ptrCast(@alignCast(version)), .open = @ptrCast(@alignCast(open)) };
}

/// find_native(name) -> the library file load_native(name) would load from
/// the native search paths, or null.
pub fn findNative(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const name = try api.argString(th, args, 0, "name");
    const file = findLibrary(vm, name) orelse return .null;
    defer vm.gpa.free(file);
    return vm.str(file);
}

/// load_native(name, [file]): the module value of the extension, or null
/// when no library for the name exists in the native search paths. With
/// file (a package's native build) that library is loaded instead of
/// searching.
pub const loadNative = if (builtin.cpu.arch.isWasm()) noNatives else loadLibrary;

/// WebAssembly (the playground) loads no native code.
fn noNatives(th: *Thread, args: []Value) Error!Value {
    _ = th;
    _ = args;
    return .null;
}

fn loadLibrary(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const name = try api.argString(th, args, 0, "name");
    const mangled = mangle(vm.gpa, name);
    defer vm.gpa.free(mangled);
    const version_sym = std.fmt.allocPrintSentinel(vm.gpa, "slang_ext_version_{s}", .{mangled}, 0) catch oom();
    defer vm.gpa.free(version_sym);
    const open_sym = std.fmt.allocPrintSentinel(vm.gpa, "slang_open_{s}", .{mangled}, 0) catch oom();
    defer vm.gpa.free(open_sym);

    const VersionFn = *const fn () callconv(.c) c_int;
    var version_fn: VersionFn = undefined;
    var open_fn: capi.CFunction = undefined;
    // linked into the executable (slang build), unless a file is asked for
    const builtin_ext = if (args.len > 1 and args[1] != .null) null else selfLookup(version_sym, open_sym);
    if (builtin_ext) |found| {
        version_fn = found.version;
        open_fn = found.open;
    } else {
        // for "a/b" the library is <path>/a/b.<ext>, which findLibrary finds
        const file = if (args.len > 1 and args[1] != .null)
            vm.gpa.dupe(u8, try api.argString(th, args, 1, "file")) catch oom()
        else
            findLibrary(vm, name) orelse return .null;
        defer vm.gpa.free(file);

        var lib = std.DynLib.open(file) catch |e| {
            return vm.raise("cannot load extension {s}: {t}", .{ file, e });
        };
        version_fn = lib.lookup(VersionFn, version_sym) orelse {
            lib.close();
            return vm.raise("{s} is not a slang extension (no {s})", .{ file, version_sym });
        };
        open_fn = lib.lookup(capi.CFunction, open_sym) orelse {
            lib.close();
            return vm.raise("extension {s} has no {s}", .{ file, open_sym });
        };
        // the library stays loaded: its functions are now reachable from slang
        vm.libraries.append(vm.gpa, lib) catch oom();
    }
    const version = version_fn();
    if (version != capi.api_version) {
        return vm.raise("extension {s} was built for API version {d}, this VM provides version {d}", .{ name, version, capi.api_version });
    }

    const fn_idx = th.top;
    try th.ensure(fn_idx + 9);
    th.push(.{ .function = blk: {
        const cl = vm.newNative(open_sym[0 .. open_sym.len], capi.callCBridge, &.{});
        cl.cfunc = open_fn;
        break :blk cl;
    } });
    try th.callInPlace(fn_idx, 0);
    const result = th.stack[fn_idx];
    th.top = fn_idx;
    return result;
}
