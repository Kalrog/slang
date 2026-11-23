//! The slang library (slang.dll, libslang.dylib, libslang.so): the VM with
//! its seed, the C API of include/slang.h, and the command line as
//! slang_main.
//!
//! - Embedding: a C or Zig program links it and uses slang_new,
//!   slang_dostring, slang_dofile and the rest of slang.h.
//! - Windows: slang.exe is a launcher (src/launcher.c) that calls
//!   slang_main, and native extensions link against slang.dll. A DLL's
//!   imports name the file they come from, so they cannot be resolved
//!   against whichever executable loads them, as they are on macOS and
//!   Linux; slang.dll is one name every program running slang shares.

const entry = @import("cli_entry.zig");

comptime {
    _ = @import("capi.zig");
    @export(&slangMain, .{ .name = "slang_main" });
}

/// slang_main(argc, argv): the slang command line (run, test, repl, ...),
/// or the program bundled into the executable that started it; its exit
/// status.
fn slangMain(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return entry.run(argc, argv, null);
}
