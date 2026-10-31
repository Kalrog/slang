//! The Zig-implemented part of the slang standard library: core globals and
//! the native modules slang/vm, slang/os, slang/string, slang/math,
//! slang/thread, slang/encoding and slang/time. The rest of the library is
//! written in slang (see slang/lib) and loaded from the embedded seed
//! bytecode.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const NativeFn = vm_mod.NativeFn;
const Error = vm_mod.Error;
const bundle = @import("../bundle/exe.zig");

pub const Native = struct {
    name: []const u8,
    f: NativeFn,
};

pub fn makeModule(vm: *VM, natives: []const Native) *Table {
    const t = vm.newTable(0, natives.len);
    for (natives) |n| t.set(vm.gpa, vm.str(n.name), vm.nativeValue(n.name, n.f));
    return t;
}

/// Installs the core globals and the preloaded native modules.
pub fn open(vm: *VM) void {
    const pkgs = vm.packages;
    pkgs.set(vm.gpa, vm.str("loaders"), .{ .table = vm.newTable(0, 0) });
    pkgs.set(vm.gpa, vm.str("preloaded"), .{ .table = vm.newTable(0, 16) });
    const sp = vm.newTable(1, 0);
    sp.append(vm.gpa, vm.str("."));
    pkgs.set(vm.gpa, vm.str("searchPaths"), .{ .table = sp });
    // native extensions: the directories in SLANG_NATIVE_PATH, ".", then
    // lib/slang and lib next to the executable's bin directory (an installed
    // slang finds <prefix>/lib/slang/*.dylib, a checkout its lib/)
    const nsp = vm.newTable(1, 0);
    if (vm.getenv("SLANG_NATIVE_PATH")) |env_path| {
        var it = std.mem.splitScalar(u8, env_path, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) nsp.append(vm.gpa, vm.str(dir));
        }
    }
    nsp.append(vm.gpa, vm.str("."));
    // a built program (slang build --dir) keeps its extensions in lib/ next to it
    if (bundle.current) |b| {
        const dir = std.fs.path.join(vm.gpa, &.{ b.exe_dir, "lib" }) catch @panic("out of memory");
        defer vm.gpa.free(dir);
        nsp.append(vm.gpa, vm.str(dir));
    }
    // where slang's own library sources are, for tools (go to definition,
    // slang doc): a checkout's slang/lib and slang/compiler, an installed
    // slang's <prefix>/lib/slang/src; module slang/x is <dir>/x.slang
    const lsp_dirs = vm.newTable(3, 0);
    // stubs: slang files that declare and document native modules and the
    // globals (never run); module x/y is <dir>/x/y.slang
    const stub_dirs = vm.newTable(2, 0);
    if (std.process.executablePathAlloc(vm.io, vm.gpa)) |exe| {
        defer vm.gpa.free(exe);
        const bin_dir = std.fs.path.dirname(exe) orelse ".";
        const source_dirs = [_][]const []const u8{
            &.{ bin_dir, "..", "slang", "lib" },
            &.{ bin_dir, "..", "slang", "compiler" },
            &.{ bin_dir, "..", "lib", "slang", "src" },
        };
        for (source_dirs) |parts| {
            const dir = std.fs.path.join(vm.gpa, parts) catch @panic("out of memory");
            defer vm.gpa.free(dir);
            lsp_dirs.append(vm.gpa, vm.str(dir));
        }
        const stub_parts = [_][]const []const u8{
            &.{ bin_dir, "..", "slang", "stubs" },
            &.{ bin_dir, "..", "lib", "slang", "stubs" },
        };
        for (stub_parts) |parts| {
            const dir = std.fs.path.join(vm.gpa, parts) catch @panic("out of memory");
            defer vm.gpa.free(dir);
            stub_dirs.append(vm.gpa, vm.str(dir));
        }
        const ext_dir = std.fs.path.join(vm.gpa, &.{ bin_dir, "..", "lib", "slang" }) catch @panic("out of memory");
        defer vm.gpa.free(ext_dir);
        nsp.append(vm.gpa, vm.str(ext_dir));
        const lib_dir = std.fs.path.join(vm.gpa, &.{ bin_dir, "..", "lib" }) catch @panic("out of memory");
        defer vm.gpa.free(lib_dir);
        nsp.append(vm.gpa, vm.str(lib_dir));
    } else |_| {}
    pkgs.set(vm.gpa, vm.str("nativeSearchPaths"), .{ .table = nsp });
    pkgs.set(vm.gpa, vm.str("librarySources"), .{ .table = lsp_dirs });
    pkgs.set(vm.gpa, vm.str("stubSources"), .{ .table = stub_dirs });
    vm.setGlobal("__PACKAGES", .{ .table = pkgs });

    @import("core.zig").open(vm);
    preload(vm, "slang/vm", .{ .table = @import("vmlib.zig").module(vm) });
    preload(vm, "slang/os", .{ .table = @import("oslib.zig").module(vm) });
    preload(vm, "slang/string", .{ .table = @import("stringlib.zig").module(vm) });
    preload(vm, "slang/math", .{ .table = @import("mathlib.zig").module(vm) });
    // C types and memory (slang/ffi's declarations, slang/buffer), always
    preload(vm, "slang/ctypes", .{ .table = @import("ctypes.zig").module(vm) });
    // calling C through libffi (slang/ffi); -Dffi=false builds without it
    if (@import("build_options").ffi) {
        preload(vm, "slang/ffi_core", .{ .table = @import("ffilib.zig").module(vm) });
    }
    preload(vm, "slang/thread", .{ .table = @import("threadlib.zig").module(vm) });
    // the browser's frames, in the Emscripten build (the playground)
    if (@import("builtin").os.tag == .emscripten) {
        preload(vm, "slang/web", .{ .table = @import("weblib.zig").module(vm) });
    }
    preload(vm, "slang/encoding", .{ .table = @import("encoding.zig").module(vm) });
    preload(vm, "slang/time", .{ .table = @import("timelib.zig").module(vm) });
    // a built program's files, and the writing of built programs (slang build)
    preload(vm, "slang/bundle", .{ .table = @import("bundlelib.zig").module(vm) });
    preload(vm, "slang/bundle_tool", .{ .table = @import("bundlelib.zig").toolModule(vm) });
}

/// Registers a module value so that require(name) finds it.
pub fn preload(vm: *VM, name: []const u8, module: Value) void {
    const entry = vm.newTable(2, 0);
    entry.append(vm.gpa, .{ .bool = true });
    entry.append(vm.gpa, module);
    vm.packages.getName("preloaded").table.set(vm.gpa, vm.str(name), .{ .table = entry });
}

/// Runs the slang-side bootstrap modules from the embedded seed:
/// slang/package (require), slang/std (module, run) and slang/compiler. A
/// module's result is registered as preloaded, so that
/// require("slang/compiler") is the instance that boot created.
pub fn boot(vm: *VM) Error!void {
    for ([_][]const u8{ "slang/package", "slang/std", "slang/compiler" }) |name| {
        const cl = (try vm.embeddedModule(name)) orelse return vm.raise("embedded module {s} not found", .{name});
        const res = try vm.call(.{ .function = cl }, &.{});
        if (res != .null) preload(vm, name, res);
    }
}
