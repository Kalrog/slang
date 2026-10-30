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
    const paths = vm.packages.getName("nativeSearchPaths").asTable() orelse return null;
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

/// load_native(name, [file]): the module value of the extension, or null
/// when no library for the name exists in the native search paths. With
/// file (a package's native build) that library is loaded instead of
/// searching.
pub fn loadNative(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const name = try api.argString(th, args, 0, "name");
    // for "a/b" the library is <path>/a/b.<ext>, which the loop above finds
    const file = if (args.len > 1 and args[1] != .null)
        vm.gpa.dupe(u8, try api.argString(th, args, 1, "file")) catch oom()
    else
        findLibrary(vm, name) orelse return .null;
    defer vm.gpa.free(file);

    var lib = std.DynLib.open(file) catch |e| {
        return vm.raise("cannot load extension {s}: {t}", .{ file, e });
    };
    const mangled = mangle(vm.gpa, name);
    defer vm.gpa.free(mangled);

    const version_sym = std.fmt.allocPrintSentinel(vm.gpa, "slang_ext_version_{s}", .{mangled}, 0) catch oom();
    defer vm.gpa.free(version_sym);
    const version_fn = lib.lookup(*const fn () callconv(.c) c_int, version_sym) orelse {
        lib.close();
        return vm.raise("{s} is not a slang extension (no {s})", .{ file, version_sym });
    };
    const version = version_fn();
    if (version != capi.api_version) {
        lib.close();
        return vm.raise("extension {s} was built for API version {d}, this VM provides version {d}", .{ file, version, capi.api_version });
    }

    const open_sym = std.fmt.allocPrintSentinel(vm.gpa, "slang_open_{s}", .{mangled}, 0) catch oom();
    defer vm.gpa.free(open_sym);
    const open_fn = lib.lookup(capi.CFunction, open_sym) orelse {
        lib.close();
        return vm.raise("extension {s} has no {s}", .{ file, open_sym });
    };
    // the library stays loaded: its functions are now reachable from slang
    vm.libraries.append(vm.gpa, lib) catch oom();

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
