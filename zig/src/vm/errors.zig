const std = @import("std");

/// Errors that cross VM boundaries. `Slang` means "a slang error was raised;
/// the details are in vm.err". `Yield` is the sentinel returned by
/// thread.yield and never reaches slang code.
pub const Error = error{ Slang, Yield };

pub const Location = struct {
    origin: []u8,
    line: u32,
    column: u32,
};

/// A slang runtime error. Location and trace are filled in by the thread at
/// the point where the error is raised, unless the creator set them (raise()
/// re-raising a caught error keeps the original ones). All memory is owned
/// by the error and freed by deinit.
pub const SlangError = struct {
    message: [:0]u8,
    loc: ?Location = null,
    trace: ?[]u8 = null,

    pub fn deinit(e: *SlangError, gpa: std.mem.Allocator) void {
        gpa.free(e.message);
        if (e.loc) |l| gpa.free(l.origin);
        if (e.trace) |t| gpa.free(t);
        e.* = undefined;
    }

    pub fn write(e: *const SlangError, w: *std.Io.Writer) !void {
        try w.print("error: {s}\n", .{e.message});
        if (e.loc) |l| try w.print("  at {s}:{d}:{d}\n", .{ l.origin, l.line, l.column });
        if (e.trace) |t| try w.print("{s}\n", .{t});
    }
};
