//! Shared between the CLI and the embedding API: the embedded seed and
//! loading of source or bytecode files.

const std = @import("std");
const seed = @import("seed");
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const Closure = vm_mod.Closure;
const Error = vm_mod.Error;

pub const embedded_files = blk: {
    var files: [seed.files.len]vm_mod.EmbeddedFile = undefined;
    for (seed.files, 0..) |f, i| files[i] = .{ .name = f.name, .data = f.data };
    break :blk files;
};

/// Loads a .slb file directly, anything else through the compiler
/// (compiler.load_main: project file, dialects, `extension global`, the bytecode cache).
pub fn loadFile(vm: *VM, path: []const u8) Error!*Closure {
    if (std.mem.endsWith(u8, path, ".slb")) {
        const data = std.Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |e| {
            return vm.raise("cannot read {s}: {t}", .{ path, e });
        };
        defer vm.gpa.free(data);
        return vm.loadBytes(data);
    }
    if (vm.getGlobal("compile") == .null) return vm.raise("no compiler available", .{});
    const compiler = try vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")});
    const load_main = compiler.table.getName("load_main");
    const res = try vm.call(load_main, &.{vm.str(path)});
    return res.asClosure() orelse vm.raise("compile did not return a function", .{});
}
