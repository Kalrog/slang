// main.zig
const std = @import("std");
const asmbl = @import("arm64.zig");
const builtin = @import("builtin");

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;
extern fn __clear_cache(start: *anyopaque, end: *anyopaque) void;

pub const Error = error{ OutOfMemory, Unsupported, TooLarge, MapFailed };

pub const JitMemory = struct {
    bytes: []align(std.heap.page_size_min) u8,

    pub fn map(len: usize) Error!JitMemory {
        const size = std.mem.alignForward(usize, len, std.heap.page_size_min);
        const prot: std.posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = builtin.os.tag == .macos };
        var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        if (builtin.os.tag == .macos) flags.JIT = true;
        const bytes = std.posix.mmap(null, size, prot, flags, -1, 0) catch return error.MapFailed;
        return .{ .bytes = bytes };
    }

    /// Copies the code in and makes it executable.
    pub fn write(self: *JitMemory, code: []const u32) Error!void {
        const src = std.mem.sliceAsBytes(code);
        if (builtin.os.tag == .macos) pthread_jit_write_protect_np(0);
        @memcpy(self.bytes[0..src.len], src);
        if (builtin.os.tag == .macos) {
            pthread_jit_write_protect_np(1);
            sys_icache_invalidate(self.bytes.ptr, src.len);
        } else {
            std.posix.mprotect(self.bytes, .{ .READ = true, .EXEC = true }) catch return error.MapFailed;
            __clear_cache(self.bytes.ptr, self.bytes.ptr + src.len);
        }
    }

    pub fn unmap(self: *JitMemory) void {
        std.posix.munmap(self.bytes);
    }

    pub fn function(self: *JitMemory, comptime Fn: type) Fn {
        const f: Fn = @ptrCast(self.bytes);
        return f;
    }
};

pub fn main() !void {
    var code: [2]u32 = @splat(0);
    var mem: JitMemory = try JitMemory.map(@sizeOf(@TypeOf(code)));
    defer mem.unmap();

    code[0] = asmbl.add(0, 0, 1);
    code[1] = asmbl.ret;
    try mem.write(&code);
    const f = mem.function(*fn (i64, i64) callconv(.c) i64);
    std.debug.print("{d}\n", .{f(3, 5)});
}
