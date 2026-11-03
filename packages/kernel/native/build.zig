//! Builds kernel/vm, the package's native module, into
//! lib/<platform>/vm.<ext> of the package (run with --prefix .., as
//! tool/build.sh does). The slang_* functions it calls are resolved
//! against the slang executable when it is loaded.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const translated = b.addTranslateC(.{
        .root_source_file = b.path("../../../zig/include/slang.h"),
        .target = target,
        .optimize = optimize,
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("vm.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("slang", translated.createModule());
    const lib = b.addLibrary(.{ .name = "vm", .linkage = .dynamic, .root_module = mod });
    lib.linker_allow_shlib_undefined = true;

    // the platform as slang's os.platform() names it
    const t = target.result;
    const os_name = switch (t.os.tag) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => @tagName(t.os.tag),
    };
    const ext = switch (t.os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
    const dir = b.fmt("lib/{s}-{s}", .{ os_name, @tagName(t.cpu.arch) });
    const install = b.addInstallFileWithDir(lib.getEmittedBin(), .{ .custom = dir }, b.fmt("vm{s}", .{ext}));
    b.getInstallStep().dependOn(&install.step);
}
