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
    const seed = seedModule(b);
    mod.addImport("seed", seed);
    // (under Emscripten emcc links libffi; -Dffi-include names its headers)
    const ffi_include = b.option([]const u8, "ffi-include", "libffi's headers (Emscripten)");
    if (with_ffi and target.result.os.tag != .emscripten) mod.linkSystemLibrary("ffi", .{});
    if (ffi_include) |dir| mod.addIncludePath(.{ .cwd_relative = dir });

    // Emscripten (the playground with raylib, see website/): Zig compiles the
    // VM to an object and emcc links it (with raylib and Emscripten's JS
    // runtime); `zig build -Dtarget=wasm32-emscripten --sysroot <emscripten
    // cache/sysroot>` installs lib/slang.o
    if (target.result.os.tag == .emscripten) {
        const obj = b.addObject(.{ .name = "slang", .root_module = mod });
        b.getInstallStep().dependOn(&b.addInstallFile(obj.getEmittedBin(), "lib/slang.o").step);
        return;
    }

    const exe = b.addExecutable(.{
        .name = "slang",
        .root_module = mod,
    });
    // Native extensions resolve slang_* symbols against the executable: the
    // exports must survive the link even though nothing in the CLI uses them.
    exe.rdynamic = true;
    exe.link_gc_sections = false;
    b.installArtifact(exe);

    // WebAssembly (the playground, see website/): the VM alone, as a WASI
    // command; nothing native loads in a browser
    if (target.result.cpu.arch.isWasm()) {
        exe.rdynamic = false;
        return;
    }

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

    // The native extensions (extensions/native), each a library installed as
    // lib/<name>.<ext>, linked against its third-party library: statically
    // where the install has a static archive (lib<x>.a), so that the
    // extension runs on machines without it (slang build --dir copies it).
    // Each is also a static archive in lib/static, with libslang.a (the
    // runtime with a C main) and manifest.slang (what to link for each), for
    // single executables with extensions built in (slang build). Every
    // extension has -D<option>=false to skip it and a prefix option (Homebrew
    // by default) for where its library is installed.
    const with_libuv = b.option(bool, "libuv", "build the uv extension (needs libuv installed)") orelse true;
    const libuv_prefix = b.option([]const u8, "libuv-prefix", "where libuv is installed") orelse "/opt/homebrew";
    const with_sqlite = b.option(bool, "sqlite", "build the sqlite extension (needs sqlite installed)") orelse true;
    const sqlite_prefix = b.option([]const u8, "sqlite-prefix", "where sqlite is installed") orelse "/opt/homebrew/opt/sqlite";
    // crypto and tls: OpenSSL 3's libcrypto and libssl
    const with_crypto = b.option(bool, "crypto", "build the crypto and tls extensions (needs OpenSSL 3 installed)") orelse true;
    const openssl_prefix = b.option([]const u8, "openssl-prefix", "where OpenSSL 3 is installed") orelse "/opt/homebrew/opt/openssl@3";
    // llhttp is vendored (extensions/native/vendor/llhttp): no prefix
    const with_llhttp = b.option(bool, "llhttp", "build the llhttp extension") orelse true;
    const with_zlib = b.option(bool, "zlib", "build the zlib extension (needs zlib installed)") orelse true;
    const zlib_prefix = b.option([]const u8, "zlib-prefix", "where zlib is installed") orelse "/opt/homebrew/opt/zlib";
    // webview: Cocoa and WebKit (macOS)
    const with_webview = b.option(bool, "webview", "build the webview extension (macOS)") orelse (target.result.os.tag == .macos);

    const natives = [_]Native{
        .{ .name = "uv", .source = "uv.c", .enabled = with_libuv, .prefix = libuv_prefix, .libs = &.{"uv"} },
        .{ .name = "sqlite", .source = "sqlite.c", .enabled = with_sqlite, .prefix = sqlite_prefix, .libs = &.{"sqlite3"} },
        .{ .name = "crypto", .source = "crypto.c", .enabled = with_crypto, .prefix = openssl_prefix, .libs = &.{"crypto"} },
        .{ .name = "tls", .source = "tls.c", .enabled = with_crypto, .prefix = openssl_prefix, .libs = &.{ "ssl", "crypto" } },
        .{
            .name = "llhttp",
            .source = "llhttp.c",
            .enabled = with_llhttp,
            .vendor = "llhttp",
            .vendor_sources = &.{ "api.c", "http.c", "llhttp.c" },
        },
        .{ .name = "zlib", .source = "zlib.c", .enabled = with_zlib, .prefix = zlib_prefix, .libs = &.{"z"} },
        .{
            .name = "webview",
            .source = "webview.m",
            .enabled = with_webview,
            .flags = &.{ "-fno-objc-arc", "-Wno-deprecated-declarations" },
            .frameworks = &.{ "Cocoa", "WebKit" },
        },
    };

    var static: StaticLibs = .{ .b = b };
    // the runtime: what main.zig is, as a library whose main is C's
    const rt_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rt_mod.addOptions("build_options", options);
    rt_mod.addImport("seed", seed);
    const rt = b.addLibrary(.{ .name = "slang", .linkage = .static, .root_module = rt_mod });
    rt.bundle_compiler_rt = true;
    static.install(b.addInstallArtifact(rt, .{ .dest_dir = .{ .override = .{ .custom = "lib/static" } } }));
    static.text.appendSlice(b.allocator, "{\n  runtime: {archives: {\"libslang.a\"}, libs: {") catch @panic("OOM");
    if (with_ffi) static.text.appendSlice(b.allocator, "\"ffi\", ") catch @panic("OOM");
    if (target.result.os.tag == .linux) static.text.appendSlice(b.allocator, "\"m\", \"dl\", \"pthread\"") catch @panic("OOM");
    static.text.appendSlice(b.allocator, "}},\n  natives: {\n") catch @panic("OOM");
    for (natives) |n| {
        if (n.enabled) addNative(b, target, optimize, n, &static);
    }
    static.text.appendSlice(b.allocator, "  },\n}\n") catch @panic("OOM");
    const manifest = b.addWriteFiles().add("manifest.slang", static.text.items);
    static.install(b.addInstallFileWithDir(manifest, .{ .custom = "lib/static" }, "manifest.slang"));

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "run the Zig unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// A native extension: one source file in extensions/native, the
/// third-party libraries it links (from prefix's include/ and lib/), the
/// frameworks (macOS), and a library vendored in extensions/native/vendor/
/// <vendor> (include/, and src/ with vendor_sources) compiled into it.
const Native = struct {
    name: []const u8,
    source: []const u8,
    enabled: bool,
    prefix: ?[]const u8 = null,
    libs: []const []const u8 = &.{},
    frameworks: []const []const u8 = &.{},
    flags: []const []const u8 = &.{"-std=c11"},
    vendor: ?[]const u8 = null,
    vendor_sources: []const []const u8 = &.{},
};

/// The module of an extension's code: its source, slang.h, its libraries'
/// headers and its vendored library (linking is the caller's).
fn nativeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, n: Native) *std.Build.Module {
    const m = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    m.addCSourceFile(.{ .file = b.path(b.fmt("../extensions/native/{s}", .{n.source})), .flags = n.flags });
    m.addIncludePath(b.path("include"));
    if (n.prefix) |prefix| m.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
    if (n.vendor) |v| {
        const dir = b.fmt("../extensions/native/vendor/{s}", .{v});
        m.addIncludePath(b.path(b.fmt("{s}/include", .{dir})));
        m.addCSourceFiles(.{ .root = b.path(b.fmt("{s}/src", .{dir})), .files = n.vendor_sources, .flags = n.flags });
    }
    return m;
}

/// What goes into lib/static, and its manifest.slang (a slang table: for
/// the runtime and each extension, the archives in lib/static to link,
/// libraries to link by name and from where, frameworks).
const StaticLibs = struct {
    b: *std.Build,
    text: std.ArrayList(u8) = .empty,
    copied: std.StringHashMapUnmanaged(void) = .empty,

    fn install(s: *StaticLibs, step: anytype) void {
        s.b.getInstallStep().dependOn(&step.step);
    }

    /// Copies prefix/lib/lib<name>.a into lib/static, once; false when the
    /// install has no static archive of it.
    fn copyArchive(s: *StaticLibs, prefix: []const u8, name: []const u8) bool {
        const b = s.b;
        const file = b.fmt("lib{s}.a", .{name});
        const path = b.fmt("{s}/lib/{s}", .{ prefix, file });
        std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
        if (s.copied.contains(file)) return true;
        s.copied.put(b.allocator, file, {}) catch @panic("OOM");
        s.install(b.addInstallFileWithDir(.{ .cwd_relative = path }, .{ .custom = "lib/static" }, file));
        return true;
    }
};

fn addNative(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, n: Native, static: *StaticLibs) void {
    const ext_name = b.fmt("{s}_ext", .{n.name});

    const m = nativeModule(b, target, optimize, n);
    if (n.prefix) |prefix| m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    for (n.libs) |lib| m.linkSystemLibrary(lib, .{ .preferred_link_mode = .static });
    for (n.frameworks) |f| m.linkFramework(f, .{});
    const lib = b.addLibrary(.{ .name = ext_name, .linkage = .dynamic, .root_module = m });
    // slang_* resolve against the executable that loads it
    lib.linker_allow_shlib_undefined = true;
    static.install(b.addInstallArtifact(lib, .{
        .dest_sub_path = b.fmt("{s}{s}", .{ n.name, target.result.dynamicLibSuffix() }),
    }));

    // the static archive: the extension (with its vendored library), its
    // other libraries are linked into the executable
    const archive = b.addLibrary(.{ .name = ext_name, .linkage = .static, .root_module = nativeModule(b, target, optimize, n) });
    static.install(b.addInstallArtifact(archive, .{ .dest_dir = .{ .override = .{ .custom = "lib/static" } } }));

    const t = &static.text;
    const a = b.allocator;
    t.print(a, "    {s}: {{archives: {{\"lib{s}.a\"", .{ n.name, ext_name }) catch @panic("OOM");
    var dynamic: std.ArrayList([]const u8) = .empty;
    for (n.libs) |l| {
        if (static.copyArchive(n.prefix.?, l)) {
            t.print(a, ", \"lib{s}.a\"", .{l}) catch @panic("OOM");
        } else {
            dynamic.append(a, l) catch @panic("OOM");
        }
    }
    t.appendSlice(a, "}, libs: {") catch @panic("OOM");
    for (dynamic.items) |l| t.print(a, "\"{s}\", ", .{l}) catch @panic("OOM");
    t.appendSlice(a, "}, lib_dirs: {") catch @panic("OOM");
    if (dynamic.items.len > 0) t.print(a, "\"{s}/lib\"", .{n.prefix.?}) catch @panic("OOM");
    t.appendSlice(a, "}, frameworks: {") catch @panic("OOM");
    for (n.frameworks) |f| t.print(a, "\"{s}\", ", .{f}) catch @panic("OOM");
    t.appendSlice(a, "}},\n") catch @panic("OOM");
}

/// The seed bytecode (slang/lib and slang/compiler compiled to .slb) lives in
/// boot/slang at the repository root. It is copied into a generated module
/// that embeds every file under its module name ("slang/compiler", ...).
fn seedModule(b: *std.Build) *std.Build.Module {
    const names = [_][]const u8{ "ast", "async", "buffer", "build", "codegen", "compiler", "crypto", "doc", "ffi", "format", "grammar", "html", "http", "inline_test", "json", "jwt", "optimizer", "package", "path", "peg", "pkg", "sqlite", "std", "symbols", "table", "test", "tls", "web", "webview", "ws", "zlib" };
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
