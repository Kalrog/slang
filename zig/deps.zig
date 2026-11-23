//! Third-party libraries built from their pinned sources (build.zig.zon,
//! lazy: fetched only by a build that needs them) where the system has no
//! copy to link: today the Windows build (x86_64-windows-gnu), which links
//! libffi into slang.dll and zlib and libuv into their extensions. Each is
//! a static library; null while the source is not fetched yet (zig build
//! fetches it and runs again).

const std = @import("std");

const Build = std.Build;
const Compile = Build.Step.Compile;

fn staticLib(b: *Build, name: []const u8, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *Compile {
    const m = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    return b.addLibrary(.{ .name = name, .linkage = .static, .root_module = m });
}

/// zlib 1.3.1: what the zlib extension links.
pub fn zlib(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*Compile {
    const dep = b.lazyDependency("zlib", .{}) orelse return null;
    const lib = staticLib(b, "z", target, optimize);
    lib.root_module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{
            "adler32.c", "compress.c", "crc32.c",   "deflate.c", "gzclose.c", "gzlib.c",   "gzread.c",
            "gzwrite.c", "infback.c",  "inffast.c", "inflate.c", "inftrees.c", "trees.c", "uncompr.c",
            "zutil.c",
        },
        .flags = &.{ "-std=c11", "-DHAVE_UNISTD_H=0" },
    });
    lib.root_module.addIncludePath(dep.path(""));
    lib.installHeadersDirectory(dep.path(""), "", .{ .include_extensions = &.{ "zlib.h", "zconf.h" } });
    return lib;
}

/// libuv 1.51.0 on Windows (src/win, as its CMakeLists.txt lists it):
/// what the uv extension links.
pub fn libuv(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*Compile {
    const dep = b.lazyDependency("libuv", .{}) orelse return null;
    const lib = staticLib(b, "uv", target, optimize);
    lib.root_module.addCSourceFiles(.{
        .root = dep.path(""),
        .files = &.{
            "src/fs-poll.c",              "src/idna.c",           "src/inet.c",              "src/random.c",
            "src/strscpy.c",              "src/strtok.c",         "src/thread-common.c",     "src/threadpool.c",
            "src/timer.c",                "src/uv-common.c",      "src/uv-data-getter-setters.c", "src/version.c",
            "src/win/async.c",            "src/win/core.c",       "src/win/detect-wakeup.c", "src/win/dl.c",
            "src/win/error.c",            "src/win/fs.c",         "src/win/fs-event.c",      "src/win/getaddrinfo.c",
            "src/win/getnameinfo.c",      "src/win/handle.c",     "src/win/loop-watcher.c",  "src/win/pipe.c",
            "src/win/thread.c",           "src/win/poll.c",       "src/win/process.c",       "src/win/process-stdio.c",
            "src/win/signal.c",           "src/win/snprintf.c",   "src/win/stream.c",        "src/win/tcp.c",
            "src/win/tty.c",              "src/win/udp.c",        "src/win/util.c",          "src/win/winapi.c",
            "src/win/winsock.c",
        },
        .flags = &.{ "-std=gnu11", "-DWIN32_LEAN_AND_MEAN", "-D_WIN32_WINNT=0x0A00", "-D_CRT_DECLARE_NONSTDC_NAMES=0" },
    });
    lib.root_module.addIncludePath(dep.path("include"));
    lib.root_module.addIncludePath(dep.path("src"));
    for ([_][]const u8{ "psapi", "user32", "advapi32", "iphlpapi", "userenv", "ws2_32", "dbghelp", "ole32", "shell32" }) |sys| {
        lib.root_module.linkSystemLibrary(sys, .{});
    }
    lib.installHeadersDirectory(dep.path("include"), "", .{});
    return lib;
}

/// libffi 3.4.8 for x86_64 Windows with the GNU toolchain (src/x86's
/// ffiw64.c and win64.S, as configure.host picks them for x86_64-*-mingw*),
/// its ffi.h and fficonfig.h made as configure would: what slang/ffi links
/// into slang.dll.
pub fn libffi(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*Compile {
    const dep = b.lazyDependency("libffi", .{}) orelse return null;
    const ffi_h = b.addConfigHeader(.{
        .style = .{ .autoconf_at = dep.path("include/ffi.h.in") },
        .include_path = "ffi.h",
    }, .{
        .VERSION = "3.4.8",
        .TARGET = "X86_WIN64",
        // (MinGW's long double is the x87 80-bit one, which libffi passes by
        // reference on Win64)
        .HAVE_LONG_DOUBLE = 1,
        .FFI_EXEC_TRAMPOLINE_TABLE = 0,
    });
    const config_h = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = dep.path("fficonfig.h.in") },
        .include_path = "fficonfig.h",
    }, .{
        .AC_APPLE_UNIVERSAL_BUILD = null,
        .EH_FRAME_FLAGS = null,
        .FFI_DEBUG = null,
        .FFI_EXEC_STATIC_TRAMP = null,
        .FFI_EXEC_TRAMPOLINE_TABLE = null,
        .FFI_MMAP_EXEC_EMUTRAMP_PAX = null,
        .FFI_MMAP_EXEC_WRIT = null,
        .FFI_NO_RAW_API = null,
        .FFI_NO_STRUCTS = null,
        .HAVE_ALLOCA_H = null,
        .HAVE_ARM64E_PTRAUTH = null,
        .HAVE_AS_CFI_PSEUDO_OP = null,
        .HAVE_AS_REGISTER_PSEUDO_OP = null,
        .HAVE_AS_S390_ZARCH = null,
        .HAVE_AS_SPARC_UA_PCREL = null,
        .HAVE_AS_X86_64_UNWIND_SECTION_TYPE = null,
        .HAVE_AS_X86_PCREL = 1,
        .HAVE_DLFCN_H = null,
        .HAVE_HIDDEN_VISIBILITY_ATTRIBUTE = null,
        .HAVE_INTTYPES_H = 1,
        .HAVE_LONG_DOUBLE = 1,
        .HAVE_LONG_DOUBLE_VARIANT = null,
        .HAVE_MEMCPY = 1,
        .HAVE_MEMFD_CREATE = null,
        .HAVE_RO_EH_FRAME = null,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRINGS_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_SYS_MEMFD_H = null,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = 1,
        .LIBFFI_GNU_SYMBOL_VERSIONING = null,
        .LT_OBJDIR = ".libs/",
        .PACKAGE = "libffi",
        .PACKAGE_BUGREPORT = "http://github.com/libffi/libffi/issues",
        .PACKAGE_NAME = "libffi",
        .PACKAGE_STRING = "libffi 3.4.8",
        .PACKAGE_TARNAME = "libffi",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = "3.4.8",
        .SIZEOF_DOUBLE = 8,
        .SIZEOF_LONG_DOUBLE = 16,
        .SIZEOF_SIZE_T = 8,
        .STDC_HEADERS = 1,
        // (x86_64 Windows symbols have no leading underscore)
        .SYMBOL_UNDERSCORE = null,
        .USING_PURIFY = null,
        .VERSION = "3.4.8",
        .WORDS_BIGENDIAN = null,
    });
    const lib = staticLib(b, "ffi", target, optimize);
    lib.root_module.addConfigHeader(ffi_h);
    lib.root_module.addConfigHeader(config_h);
    lib.root_module.addIncludePath(dep.path("include"));
    lib.root_module.addIncludePath(dep.path("src/x86"));
    lib.root_module.addCSourceFiles(.{
        .root = dep.path("src"),
        .files = &.{ "prep_cif.c", "types.c", "raw_api.c", "java_raw_api.c", "closures.c", "tramp.c", "x86/ffiw64.c", "x86/win64.S" },
        .flags = &.{ "-DFFI_STATIC_BUILD", "-DX86_WIN64" },
    });
    lib.installConfigHeader(ffi_h);
    lib.installHeader(dep.path("src/x86/ffitarget.h"), "ffitarget.h");
    return lib;
}
