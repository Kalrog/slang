//! Builds midi/native, the package's native module (midi.c, on CoreMIDI
//! on macOS), into lib/<platform>/native.<ext> of the package (run with
//! --prefix .., as tool/build.sh does). The slang_* functions it calls are
//! resolved against the slang executable when it is loaded.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    mod.addCSourceFile(.{ .file = b.path("midi.c"), .flags = &.{"-std=c11"} });
    mod.addIncludePath(b.path("../../../zig/include"));
    const t = target.result;
    if (t.os.tag == .macos) {
        mod.linkFramework("CoreMIDI", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
    const lib = b.addLibrary(.{ .name = "native", .linkage = .dynamic, .root_module = mod });
    lib.linker_allow_shlib_undefined = true;

    // the platform as slang's os.platform() names it
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
    const install = b.addInstallFileWithDir(lib.getEmittedBin(), .{ .custom = dir }, b.fmt("native{s}", .{ext}));
    b.getInstallStep().dependOn(&install.step);
}
