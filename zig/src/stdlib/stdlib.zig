//! The Zig-implemented part of the slang standard library: core globals and
//! the native modules slang/vm, slang/os, slang/string, slang/math and
//! slang/thread. The rest of the library is written in slang (see
//! slang/lib) and loaded from the embedded seed bytecode.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const NativeFn = vm_mod.NativeFn;
const Error = vm_mod.Error;

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
    // native extensions: "." plus the directories in SLANG_NATIVE_PATH
    const nsp = vm.newTable(1, 0);
    nsp.append(vm.gpa, vm.str("."));
    if (vm.getenv("SLANG_NATIVE_PATH")) |env_path| {
        var it = std.mem.splitScalar(u8, env_path, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) nsp.append(vm.gpa, vm.str(dir));
        }
    }
    pkgs.set(vm.gpa, vm.str("nativeSearchPaths"), .{ .table = nsp });
    vm.setGlobal("__PACKAGES", .{ .table = pkgs });

    @import("core.zig").open(vm);
    preload(vm, "slang/vm", .{ .table = @import("vmlib.zig").module(vm) });
    preload(vm, "slang/os", .{ .table = @import("oslib.zig").module(vm) });
    preload(vm, "slang/string", .{ .table = @import("stringlib.zig").module(vm) });
    preload(vm, "slang/math", .{ .table = @import("mathlib.zig").module(vm) });
    preload(vm, "slang/thread", .{ .table = @import("threadlib.zig").module(vm) });
}

/// Registers a module value so that require(name) finds it.
pub fn preload(vm: *VM, name: []const u8, module: Value) void {
    const entry = vm.newTable(2, 0);
    entry.append(vm.gpa, .{ .bool = true });
    entry.append(vm.gpa, module);
    vm.packages.getName("preloaded").table.set(vm.gpa, vm.str(name), .{ .table = entry });
}

/// Runs the slang-side bootstrap modules from the embedded seed:
/// slang/package (require), slang/std (module, run) and slang/compiler.
pub fn boot(vm: *VM) Error!void {
    for ([_][]const u8{ "slang/package", "slang/std", "slang/compiler" }) |name| {
        const cl = (try vm.embeddedModule(name)) orelse return vm.raise("embedded module {s} not found", .{name});
        _ = try vm.call(.{ .function = cl }, &.{});
    }
}
