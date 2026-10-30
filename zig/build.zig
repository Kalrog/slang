const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gc_stress = b.option(bool, "gc-stress", "collect garbage on every allocation") orelse false;
    // the FFI (slang/ffi) links libffi: the system's on macOS, libffi.so
    // (libffi-dev) on Linux; -Dffi=false leaves it out
    const with_ffi = b.option(bool, "ffi", "build slang/ffi (links libffi)") orelse true;
    const options = b.addOptions();
    options.addOption(bool, "gc_stress", gc_stress);
    options.addOption(bool, "ffi", with_ffi);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    mod.addImport("seed", seedModule(b));
    if (with_ffi) mod.linkSystemLibrary("ffi", .{});

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

    // A plain C library for the FFI tests (zig/test/ffi_test.slang), installed
    // as lib/libffitest.<ext> where slang/ffi's load("ffitest") finds it.
    if (with_ffi) {
        const ft_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        ft_mod.addCSourceFile(.{ .file = b.path("test/ffitest.c"), .flags = &.{"-std=c11"} });
        const ft = b.addLibrary(.{ .name = "ffitest", .linkage = .dynamic, .root_module = ft_mod });
        b.installArtifact(ft);
    }

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

    // The uv extension links the system libuv (Homebrew by default);
    // -Dlibuv=false skips it, -Dlibuv-prefix points at another install.
    const with_libuv = b.option(bool, "libuv", "build the uv extension (needs libuv installed)") orelse true;
    if (with_libuv) {
        const prefix = b.option([]const u8, "libuv-prefix", "where libuv is installed") orelse "/opt/homebrew";
        const uv_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        uv_mod.addCSourceFile(.{ .file = b.path("../extensions/native/uv.c"), .flags = &.{"-std=c11"} });
        uv_mod.addIncludePath(b.path("include"));
        uv_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        uv_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        uv_mod.linkSystemLibrary("uv", .{});
        const uv = b.addLibrary(.{ .name = "uv_ext", .linkage = .dynamic, .root_module = uv_mod });
        uv.linker_allow_shlib_undefined = true;
        const uv_install = b.addInstallArtifact(uv, .{
            .dest_sub_path = b.fmt("uv{s}", .{target.result.dynamicLibSuffix()}),
        });
        b.getInstallStep().dependOn(&uv_install.step);
    }

    // The sqlite extension links the system SQLite (Homebrew by default);
    // -Dsqlite=false skips it, -Dsqlite-prefix points at another install.
    const with_sqlite = b.option(bool, "sqlite", "build the sqlite extension (needs sqlite installed)") orelse true;
    if (with_sqlite) {
        const prefix = b.option([]const u8, "sqlite-prefix", "where sqlite is installed") orelse "/opt/homebrew/opt/sqlite";
        const sq_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        sq_mod.addCSourceFile(.{ .file = b.path("../extensions/native/sqlite.c"), .flags = &.{"-std=c11"} });
        sq_mod.addIncludePath(b.path("include"));
        sq_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        sq_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        sq_mod.linkSystemLibrary("sqlite3", .{});
        const sq = b.addLibrary(.{ .name = "sqlite_ext", .linkage = .dynamic, .root_module = sq_mod });
        sq.linker_allow_shlib_undefined = true;
        const sq_install = b.addInstallArtifact(sq, .{
            .dest_sub_path = b.fmt("sqlite{s}", .{target.result.dynamicLibSuffix()}),
        });
        b.getInstallStep().dependOn(&sq_install.step);
    }

    // The crypto extension links OpenSSL 3's libcrypto (Homebrew by default);
    // -Dcrypto=false skips it, -Dopenssl-prefix points at another install.
    const with_crypto = b.option(bool, "crypto", "build the crypto extension (needs OpenSSL 3 installed)") orelse true;
    if (with_crypto) {
        const prefix = b.option([]const u8, "openssl-prefix", "where OpenSSL 3 is installed") orelse "/opt/homebrew/opt/openssl@3";
        const cr_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        cr_mod.addCSourceFile(.{ .file = b.path("../extensions/native/crypto.c"), .flags = &.{"-std=c11"} });
        cr_mod.addIncludePath(b.path("include"));
        cr_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        cr_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        cr_mod.linkSystemLibrary("crypto", .{});
        const cr = b.addLibrary(.{ .name = "crypto_ext", .linkage = .dynamic, .root_module = cr_mod });
        cr.linker_allow_shlib_undefined = true;
        const cr_install = b.addInstallArtifact(cr, .{
            .dest_sub_path = b.fmt("crypto{s}", .{target.result.dynamicLibSuffix()}),
        });
        b.getInstallStep().dependOn(&cr_install.step);

        // The tls extension: libssl from the same install.
        const tls_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        tls_mod.addCSourceFile(.{ .file = b.path("../extensions/native/tls.c"), .flags = &.{"-std=c11"} });
        tls_mod.addIncludePath(b.path("include"));
        tls_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        tls_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        tls_mod.linkSystemLibrary("ssl", .{});
        tls_mod.linkSystemLibrary("crypto", .{});
        const tls = b.addLibrary(.{ .name = "tls_ext", .linkage = .dynamic, .root_module = tls_mod });
        tls.linker_allow_shlib_undefined = true;
        const tls_install = b.addInstallArtifact(tls, .{
            .dest_sub_path = b.fmt("tls{s}", .{target.result.dynamicLibSuffix()}),
        });
        b.getInstallStep().dependOn(&tls_install.step);
    }

    // The llhttp extension links llhttp (Homebrew by default); -Dllhttp=false
    // skips it, -Dllhttp-prefix points at another install.
    const with_llhttp = b.option(bool, "llhttp", "build the llhttp extension (needs llhttp installed)") orelse true;
    if (with_llhttp) {
        const prefix = b.option([]const u8, "llhttp-prefix", "where llhttp is installed") orelse "/opt/homebrew/opt/llhttp";
        addNativeExtension(b, target, optimize, "llhttp", "../extensions/native/llhttp.c", prefix, "llhttp");
    }

    // The zlib extension links zlib (Homebrew by default); -Dzlib=false skips
    // it, -Dzlib-prefix points at another install.
    const with_zlib = b.option(bool, "zlib", "build the zlib extension (needs zlib installed)") orelse true;
    if (with_zlib) {
        const prefix = b.option([]const u8, "zlib-prefix", "where zlib is installed") orelse "/opt/homebrew/opt/zlib";
        addNativeExtension(b, target, optimize, "zlib", "../extensions/native/zlib.c", prefix, "z");
    }

    // The webview extension (macOS: Cocoa and WebKit); -Dwebview=false skips it.
    const with_webview = b.option(bool, "webview", "build the webview extension (macOS)") orelse (target.result.os.tag == .macos);
    if (with_webview) {
        const wv_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        wv_mod.addCSourceFile(.{ .file = b.path("../extensions/native/webview.m"), .flags = &.{ "-fno-objc-arc", "-Wno-deprecated-declarations" } });
        wv_mod.addIncludePath(b.path("include"));
        wv_mod.linkFramework("Cocoa", .{});
        wv_mod.linkFramework("WebKit", .{});
        const wv = b.addLibrary(.{ .name = "webview_ext", .linkage = .dynamic, .root_module = wv_mod });
        wv.linker_allow_shlib_undefined = true;
        const wv_install = b.addInstallArtifact(wv, .{
            .dest_sub_path = b.fmt("webview{s}", .{target.result.dynamicLibSuffix()}),
        });
        b.getInstallStep().dependOn(&wv_install.step);
    }

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "run the Zig unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// A native extension built from one C file against a library installed
/// under prefix (include/ and lib/), installed as lib/<name>.dylib.
fn addNativeExtension(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, source: []const u8, prefix: []const u8, library: []const u8) void {
    const m = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    m.addCSourceFile(.{ .file = b.path(source), .flags = &.{"-std=c11"} });
    m.addIncludePath(b.path("include"));
    m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    m.linkSystemLibrary(library, .{});
    const lib = b.addLibrary(.{ .name = b.fmt("{s}_ext", .{name}), .linkage = .dynamic, .root_module = m });
    lib.linker_allow_shlib_undefined = true;
    const install = b.addInstallArtifact(lib, .{
        .dest_sub_path = b.fmt("{s}{s}", .{ name, target.result.dynamicLibSuffix() }),
    });
    b.getInstallStep().dependOn(&install.step);
}

/// The seed bytecode (slang/lib and slang/compiler compiled to .slb) lives in
/// boot/slang at the repository root. It is copied into a generated module
/// that embeds every file under its module name ("slang/compiler", ...).
fn seedModule(b: *std.Build) *std.Build.Module {
    const names = [_][]const u8{ "ast", "async", "buffer", "codegen", "compiler", "crypto", "doc", "ffi", "format", "grammar", "html", "http", "json", "jwt", "optimizer", "package", "peg", "pkg", "sqlite", "std", "symbols", "table", "test", "tls", "web", "webview", "ws" };
    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "pub const Entry = struct { name: []const u8, data: []const u8 };\npub const files = [_]Entry{\n") catch @panic("OOM");
    for (names) |n| {
        const file = b.fmt("{s}.slb", .{n});
        _ = wf.addCopyFile(b.path(b.fmt("../boot/slang/{s}", .{file})), file);
        src.appendSlice(b.allocator, b.fmt("    .{{ .name = \"slang/{s}\", .data = @embedFile(\"{s}\") }},\n", .{ n, file })) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const root = wf.add("seed.zig", src.items);
    return b.createModule(.{ .root_source_file = root });
}
