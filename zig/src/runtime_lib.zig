//! libslang.a: the slang executable as a static library whose main is C's,
//! so that `slang build` can link a program's native extensions into one
//! executable (with the system's cc or zig cc; nothing is compiled). It is
//! main.zig started as cli_entry.zig starts it.

const entry = @import("cli_entry.zig");

comptime {
    @export(&cMain, .{ .name = "main" });
}

fn cMain(argc: c_int, argv: [*][*:0]u8, envp: [*:null]?[*:0]u8) callconv(.c) c_int {
    return entry.run(argc, argv, envp);
}
