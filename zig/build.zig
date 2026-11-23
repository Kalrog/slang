const std = @import("std");
const deps = @import("deps.zig");

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
    // (Windows has no system libffi: it is built from source, see deps.zig)
    const windows_ffi = if (with_ffi and target.result.os.tag == .windows) deps.libffi(b, target, optimize) else null;
    if (windows_ffi) |lib| {
        mod.linkLibrary(lib);
    } else if (with_ffi and target.result.os.tag != .emscripten and target.result.os.tag != .windows) {
        mod.linkSystemLibrary("ffi", .{});
    }
    if (ffi_include) |dir| mod.addIncludePath(.{ .cwd_relative = dir });

    // Emscripten (the playground with raylib, see website/): Zig compiles the
    // VM to an object and emcc links it (with raylib and Emscripten's JS
    // runtime); `zig build -Dtarget=wasm32-emscripten --sysroot <emscripten
    // cache/sysroot>` installs lib/slang.o. slang.h's printf-style functions
    // (src/capi_varargs.c) are not in it: emcc compiles and links them.
    if (target.result.os.tag == .emscripten) {
        const obj = b.addObject(.{ .name = "slang", .root_module = mod });
        b.getInstallStep().dependOn(&b.addInstallFile(obj.getEmittedBin(), "lib/slang.o").step);
        return;
    }

    // slang.h's printf-style functions are C (see src/capi_varargs.c)
    mod.addCSourceFile(.{ .file = b.path("src/capi_varargs.c"), .flags = &.{"-std=c11"} });

    const windows = target.result.os.tag == .windows;
    // (the debugger's sockets are Winsock on Windows)
    if (windows) mod.linkSystemLibrary("ws2_32", .{});

    // The slang library (src/lib.zig): the VM, the C API and the command
    // line as slang_main; slang.dll, libslang.dylib or libslang.so. A C or
    // Zig program embeds slang by linking it.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addOptions("build_options", options);
    lib_mod.addImport("seed", seed);
    lib_mod.addCSourceFile(.{ .file = b.path("src/capi_varargs.c"), .flags = &.{"-std=c11"} });
    if (windows_ffi) |lib| {
        lib_mod.linkLibrary(lib);
    } else if (with_ffi and !target.result.cpu.arch.isWasm() and !windows) {
        lib_mod.linkSystemLibrary("ffi", .{});
    }
    if (windows) lib_mod.linkSystemLibrary("ws2_32", .{});
    const shared = b.addLibrary(.{ .name = "slang", .linkage = .dynamic, .root_module = lib_mod });
    shared.link_gc_sections = false;
    if (!target.result.cpu.arch.isWasm()) b.installArtifact(shared);

    // The executable. On Windows a launcher calling slang.dll's slang_main:
    // a DLL's imports name the file they come from, so native extensions
    // link against slang.dll, which every program running slang loads. On
    // macOS and Linux it is the whole VM, and extensions resolve slang_*
    // against it at load time.
    const exe = if (windows) blk: {
        const launcher_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        launcher_mod.addCSourceFile(.{ .file = b.path("src/launcher.c"), .flags = &.{"-std=c11"} });
        launcher_mod.linkLibrary(shared);
        break :blk b.addExecutable(.{ .name = "slang", .root_module = launcher_mod });
    } else b.addExecutable(.{
        .name = "slang",
        .root_module = mod,
    });
    if (!windows) {
        // the exports must survive the link even though nothing in the CLI
        // uses them
        exe.rdynamic = true;
        exe.link_gc_sections = false;
    }
    b.installArtifact(exe);


    // WebAssembly (the playground, see website/): the VM alone, as a WASI
    // command; nothing native loads in a browser
    if (target.result.cpu.arch.isWasm()) {
        exe.rdynamic = false;
        // what a page calls to go on with a program that yielded (main.zig)
        exe.root_module.export_symbol_names = &.{"slang_resume"};
        return;
    }

    // Example native extensions (extensions/native), installed into
    // zig-out/lib where zig/test/native_test.slang finds them. Their slang_*
    // references are resolved against the executable at load time.
    const hello_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    hello_mod.addCSourceFile(.{ .file = b.path("../extensions/native/hello.c"), .flags = &.{"-std=c11"} });
    hello_mod.addIncludePath(b.path("include"));
    const hello = b.addLibrary(.{ .name = "hello", .linkage = .dynamic, .root_module = hello_mod });
    linkExtension(hello, shared, windows);
    installExtension(b, hello, windows);

    // A plain C library for the FFI tests (zig/test/ffi_test.slang), installed
    // as lib/libffitest.<ext> where slang/ffi's load("ffitest") finds it.
    if (with_ffi) {
        const ft_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        ft_mod.addCSourceFile(.{ .file = b.path("test/ffitest.c"), .flags = &.{"-std=c11"} });
        const ft = b.addLibrary(.{ .name = "ffitest", .linkage = .dynamic, .root_module = ft_mod });
        installExtension(b, ft, windows);
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
    linkExtension(vec, shared, windows);
    installExtension(b, vec, windows);

    // The vector benchmark's libraries (bench/vectors, `make bench-vectors`):
    // a Zig extension and a C library for slang/ffi, into build/bench under
    // the prefix only by the bench-libs step, never with the install.
    const bench_libs = b.step("bench-libs", "the vector benchmark's native libraries, into build/bench");
    const v3_mod = b.createModule(.{
        .root_source_file = b.path("../bench/vectors/native/vec3.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    v3_mod.addImport("slang", translated.createModule());
    const v3 = b.addLibrary(.{ .name = "vec3", .linkage = .dynamic, .root_module = v3_mod });
    v3.linker_allow_shlib_undefined = true;
    const cv3_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    cv3_mod.addCSourceFile(.{ .file = b.path("../bench/vectors/native/cvec3.c"), .flags = &.{ "-std=c11", "-O2" } });
    const cv3 = b.addLibrary(.{ .name = "cvec3", .linkage = .dynamic, .root_module = cv3_mod });
    for ([_]*std.Build.Step.Compile{ v3, cv3 }) |lib| {
        bench_libs.dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "build/bench" } } }).step);
    }

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
    // sqlite: built from its pinned source (deps.zig), on every platform
    const with_sqlite = b.option(bool, "sqlite", "build the sqlite extension") orelse true;
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
        .{ .name = "sqlite", .source = "sqlite.c", .enabled = with_sqlite, .from_source = deps.sqlite },
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

    // Windows: the extensions with their libraries built from source
    // (deps.zig), linked against slang.dll. crypto, tls and webview, and
    // lib/static for `slang build`, are not built there yet.
    if (windows) {
        for (natives) |n| {
            if (!n.enabled) continue;
            const dep: ?*std.Build.Step.Compile = if (n.from_source) |f|
                f(b, target, optimize) orelse continue
            else if (std.mem.eql(u8, n.name, "uv"))
                deps.libuv(b, target, optimize) orelse continue
            else if (std.mem.eql(u8, n.name, "zlib"))
                deps.zlib(b, target, optimize) orelse continue
            else if (n.vendor != null)
                null
            else
                continue;
            addWindowsNative(b, target, optimize, n, dep, shared);
        }
        return;
    }

    var static: StaticLibs = .{ .b = b };
    // the runtime: what main.zig is, as a library whose main is C's
    const rt_mod = b.createModule(.{
        .root_source_file = b.path("src/runtime_lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    rt_mod.addOptions("build_options", options);
    rt_mod.addCSourceFile(.{ .file = b.path("src/capi_varargs.c"), .flags = &.{"-std=c11"} });
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
    const test_step = b.step("test", "run the Zig unit tests and the embedding test");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // a C program embedding slang through the slang library
    const embed_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    embed_mod.addCSourceFile(.{ .file = b.path("test/embed.c"), .flags = &.{"-std=c11"} });
    embed_mod.addIncludePath(b.path("include"));
    embed_mod.linkLibrary(shared);
    const embed = b.addExecutable(.{ .name = "embed_test", .root_module = embed_mod });
    test_step.dependOn(&b.addRunArtifact(embed).step);
}

/// Installs a library the tests load: into lib/ (on Windows too, where a
/// DLL would go to bin/ by default), where slang's native search paths and
/// slang/ffi look.
fn installExtension(b: *std.Build, lib: *std.Build.Step.Compile, windows: bool) void {
    if (windows) {
        b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .lib },
            .implib_dir = .disabled,
            .pdb_dir = .disabled,
        }).step);
    } else {
        b.installArtifact(lib);
    }
}

/// How an extension library reaches the VM's slang_*: on Windows it links
/// against slang.dll (a DLL's imports name their file); elsewhere they stay
/// undefined and resolve against the program that loads it.
fn linkExtension(lib: *std.Build.Step.Compile, shared: *std.Build.Step.Compile, windows: bool) void {
    if (windows) {
        lib.root_module.linkLibrary(shared);
    } else {
        lib.linker_allow_shlib_undefined = true;
    }
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
    /// its library built from pinned source (deps.zig) and linked in
    from_source: ?*const fn (*std.Build, std.Build.ResolvedTarget, std.builtin.OptimizeMode) ?*std.Build.Step.Compile = null,
};

/// The module of an extension's code: its source, slang.h, its libraries'
/// headers and its vendored library (linking is the caller's).
fn nativeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, n: Native) *std.Build.Module {
    const m = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    // (strict C11 hides POSIX's strdup and its kind from glibc's and musl's
    // headers; macOS's show them anyway)
    m.addCMacro("_DEFAULT_SOURCE", "1");
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

    // a library from source: linked into the extension, and its archive
    // into lib/static for executables
    const from_source: ?*std.Build.Step.Compile = if (n.from_source) |f| (f(b, target, optimize) orelse return) else null;
    const m = nativeModule(b, target, optimize, n);
    if (from_source) |d| m.linkLibrary(d);
    if (n.prefix) |prefix| m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
    // Homebrew's archives are position-independent and go into the
    // extension; a Linux distribution's (libuv.a, libz.a) are not, and
    // cannot: there the extension links the shared library
    const link_mode: std.builtin.LinkMode = if (target.result.os.tag.isDarwin()) .static else .dynamic;
    for (n.libs) |lib| m.linkSystemLibrary(lib, .{ .preferred_link_mode = link_mode });
    for (n.frameworks) |f| m.linkFramework(f, .{});
    const lib = b.addLibrary(.{ .name = ext_name, .linkage = .dynamic, .root_module = m });
    // slang_* resolve against the executable that loads it
    lib.linker_allow_shlib_undefined = true;
    static.install(b.addInstallArtifact(lib, .{
        .dest_sub_path = b.fmt("{s}{s}", .{ n.name, target.result.dynamicLibSuffix() }),
    }));

    // the static archive: the extension (with its vendored library), its
    // other libraries are linked into the executable
    const archive_mod = nativeModule(b, target, optimize, n);
    if (from_source) |d| archive_mod.addIncludePath(d.getEmittedIncludeTree());
    const archive = b.addLibrary(.{ .name = ext_name, .linkage = .static, .root_module = archive_mod });
    static.install(b.addInstallArtifact(archive, .{ .dest_dir = .{ .override = .{ .custom = "lib/static" } } }));
    if (from_source) |d| static.install(b.addInstallArtifact(d, .{ .dest_dir = .{ .override = .{ .custom = "lib/static" } }, .h_dir = .disabled }));

    const t = &static.text;
    const a = b.allocator;
    t.print(a, "    {s}: {{archives: {{\"lib{s}.a\"", .{ n.name, ext_name }) catch @panic("OOM");
    if (from_source) |d| t.print(a, ", \"lib{s}.a\"", .{d.name}) catch @panic("OOM");
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

/// A native extension on Windows: lib/<name>.dll, with its library built
/// from source (deps.zig) linked in statically, importing slang_* from
/// slang.dll.
fn addWindowsNative(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, n: Native, dep: ?*std.Build.Step.Compile, shared: *std.Build.Step.Compile) void {
    const m = nativeModule(b, target, optimize, .{
        .name = n.name,
        .source = n.source,
        .enabled = true,
        .flags = n.flags,
        .vendor = n.vendor,
        .vendor_sources = n.vendor_sources,
    });
    if (dep) |d| m.linkLibrary(d);
    const lib = b.addLibrary(.{ .name = b.fmt("{s}_ext", .{n.name}), .linkage = .dynamic, .root_module = m });
    linkExtension(lib, shared, true);
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .lib },
        .dest_sub_path = b.fmt("{s}.dll", .{n.name}),
        .implib_dir = .disabled,
        .pdb_dir = .disabled,
    }).step);
}

/// The seed bytecode (slang/lib and slang/compiler compiled to .slb) lives in
/// boot/slang at the repository root. It is copied into a generated module
/// that embeds every file under its module name ("slang/compiler", ...).
/// The grammar extensions of libraries the binary carries are in it too
/// (boot/extensions, as "extensions/html", ...): `extension
/// "extensions/html"` works wherever slang runs, not only in a checkout.
fn seedModule(b: *std.Build) *std.Build.Module {
    const names = [_][]const u8{ "ast", "async", "buffer", "build", "codegen", "compiler", "crypto", "doc", "ffi", "format", "grammar", "html", "http", "json", "jwt", "net", "optimizer", "parse_error", "resolve", "package", "path", "peg", "pegc", "pegc_root", "pkg", "sqlite", "std", "symbols", "test", "tls", "web", "webview", "ws", "zlib" };
    const wf = b.addWriteFiles();
    var src: std.ArrayList(u8) = .empty;
    src.appendSlice(b.allocator, "pub const Entry = struct { name: []const u8, data: []const u8 };\npub const files = [_]Entry{\n") catch @panic("OOM");
    for (names) |n| {
        const file = b.fmt("{s}.slb", .{n});
        _ = wf.addCopyFile(b.path(b.fmt("../boot/slang/{s}", .{file})), file);
        src.appendSlice(b.allocator, b.fmt("    .{{ .name = \"slang/{s}\", .data = @embedFile(\"{s}\") }},\n", .{ n, file })) catch @panic("OOM");
    }
    // (slang/async, slang/html, slang/test, slang/json and slang/sqlite have one)
    const extensions = [_][]const u8{ "async", "html", "inline_test", "json", "sqlite" };
    for (extensions) |n| {
        const file = b.fmt("ext_{s}.slb", .{n});
        _ = wf.addCopyFile(b.path(b.fmt("../boot/extensions/{s}.slb", .{n})), file);
        src.appendSlice(b.allocator, b.fmt("    .{{ .name = \"extensions/{s}\", .data = @embedFile(\"{s}\") }},\n", .{ n, file })) catch @panic("OOM");
    }
    src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    const root = wf.add("seed.zig", src.items);
    return b.createModule(.{ .root_source_file = root });
}
