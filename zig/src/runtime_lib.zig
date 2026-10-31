//! libslang.a: the slang executable as a static library whose main is C's,
//! so that `slang build` can link a program's native extensions into one
//! executable (with the system's cc or zig cc; nothing is compiled). It is
//! main.zig with what std.start does for an executable: the arguments, the
//! environment, an allocator and the I/O implementation.

const std = @import("std");
const cli = @import("main.zig");

comptime {
    @export(&cMain, .{ .name = "main" });
}

fn cMain(argc: c_int, argv: [*][*:0]u8, envp: [*:null]?[*:0]u8) callconv(.c) c_int {
    var n: usize = 0;
    while (envp[n] != null) n += 1;
    const block: std.process.Environ.Block = .{ .slice = envp[0..n :null] };
    const args = argv[0..@intCast(argc)];
    const gpa = std.heap.c_allocator;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    var threaded: std.Io.Threaded = .init(gpa, .{ .argv0 = .init(.{ .vector = args }), .environ = .{ .block = block } });
    defer threaded.deinit();
    var environ_map = std.process.Environ.createMap(.{ .block = block }, gpa) catch return 1;
    defer environ_map.deinit();
    const preopens = std.process.Preopens.init(arena.allocator()) catch return 1;
    return cli.main(.{
        .minimal = .{ .args = .{ .vector = args }, .environ = .{ .block = block } },
        .arena = &arena,
        .gpa = gpa,
        .io = threaded.io(),
        .environ_map = &environ_map,
        .preopens = preopens,
    }) catch 1;
}
