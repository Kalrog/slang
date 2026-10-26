const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gc_stress = b.option(bool, "gc-stress", "collect garbage on every allocation") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "gc_stress", gc_stress);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    mod.addImport("seed", seedModule(b));

    const exe = b.addExecutable(.{
        .name = "slang",
        .root_module = mod,
    });
    // Native extensions resolve slang_* symbols against the executable: the
    // exports must survive the link even though nothing in the CLI uses them.
    exe.rdynamic = true;
    exe.link_gc_sections = false;
    b.installArtifact(exe);

    // Example native extensions (extensions/native), installed into
    // zig-out/lib where zig/test/native_test.slang finds them. Their slang_*
    // references are resolved against the executable at load time.
    const hello_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    hello_mod.addCSourceFile(.{ .file = b.path("../extensions/native/hello.c"), .flags = &.{"-std=c11"} });
    hello_mod.addIncludePath(b.path("include"));
    const hello = b.addLibrary(.{ .name = "hello", .linkage = .dynamic, .root_module = hello_mod });
    hello.linker_allow_shlib_undefined = true;
    b.installArtifact(hello);

    // Zig extensions import the header through translate-c as "slang".
    const translated = b.addTranslateC(.{
        .root_source_file = b.path("include/slang.h"),
        .target = target,
        .optimize = optimize,
    });
    const vec_mod = b.createModule(.{
        .root_source_file = b.path("../extensions/native/vec.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vec_mod.addImport("slang", translated.createModule());
    const vec = b.addLibrary(.{ .name = "vec", .linkage = .dynamic, .root_module = vec_mod });
    vec.linker_allow_shlib_undefined = true;
    b.installArtifact(vec);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "run the Zig unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// The seed bytecode (slang/lib and slang/compiler compiled to .slb) lives in
/// go/boot/slang until go/ is removed. It is copied into a generated module
/// that embeds every file under its module name ("slang/compiler", ...).
fn seedModule(b: *std.Build) *std.Build.Module {
    const names = [_][]const u8{ "ast", "codegen", "compiler", "grammar", "optimizer", "package", "peg", "std", "table", "test" };
    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "pub const Entry = struct { name: []const u8, data: []const u8 };\npub const files = [_]Entry{\n") catch @panic("OOM");
    for (names) |n| {
        const file = b.fmt("{s}.slb", .{n});
        _ = wf.addCopyFile(b.path(b.fmt("../go/boot/slang/{s}", .{file})), file);
        src.appendSlice(b.allocator, b.fmt("    .{{ .name = \"slang/{s}\", .data = @embedFile(\"{s}\") }},\n", .{ n, file })) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const root = wf.add("seed.zig", src.items);
    return b.createModule(.{ .root_source_file = root });
}
