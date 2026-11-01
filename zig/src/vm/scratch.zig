const std = @import("std");
const Allocator = std.mem.Allocator;
const oom = @import("../vm.zig").oom;

/// Temporary memory for calls into C (slang/ffi): a block that grows to
/// the largest call seen and then stays, carved out in stack order. A call
/// takes a mark, carves what it needs and releases back to the mark, so
/// nested calls (a callback that calls C again) stack on the same thread.
/// Carved memory never moves: C holds pointers into it during the call.
pub const Scratch = struct {
    buf: []align(16) u8 = &.{},
    top: usize = 0,
    /// the most the block was asked for at once, for growing it
    peak: usize = 0,
    /// blocks allocated when the buffer was full
    spill: std.ArrayList([]align(16) u8) = .empty,

    pub const Mark = struct { top: usize, spill: usize };
    pub const initial = 16 * 1024;

    pub fn mark(s: *const Scratch) Mark {
        return .{ .top = s.top, .spill = s.spill.items.len };
    }

    /// n bytes, 16-aligned, uninitialised.
    pub inline fn bytes(s: *Scratch, gpa: Allocator, n: usize) [*]align(16) u8 {
        const need = std.mem.alignForward(usize, n, 16);
        if (s.buf.len == 0) s.buf = gpa.alignedAlloc(u8, .@"16", initial) catch oom();
        if (s.top + need <= s.buf.len) {
            const p: [*]align(16) u8 = @alignCast(s.buf.ptr + s.top);
            s.top += need;
            return p;
        }
        s.peak = @max(s.peak, s.top + need);
        const block = gpa.alignedAlloc(u8, .@"16", need) catch oom();
        s.spill.append(gpa, block) catch oom();
        return block.ptr;
    }

    pub fn array(s: *Scratch, gpa: Allocator, comptime T: type, n: usize) []T {
        const p = s.bytes(gpa, n * @sizeOf(T));
        return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
    }

    /// Gives back everything carved since the mark. Once nothing is in use
    /// a buffer that spilled grows to what was needed.
    pub inline fn release(s: *Scratch, gpa: Allocator, m: Mark) void {
        while (s.spill.items.len > m.spill) gpa.free(s.spill.pop().?);
        s.top = m.top;
        if (s.top == 0 and s.peak > s.buf.len) {
            gpa.free(s.buf);
            s.buf = gpa.alignedAlloc(u8, .@"16", std.mem.alignForward(usize, s.peak, 4096)) catch oom();
            s.peak = 0;
        }
    }

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        for (s.spill.items) |b| gpa.free(b);
        s.spill.deinit(gpa);
        if (s.buf.len > 0) gpa.free(s.buf);
        s.* = .{};
    }
};

test "carve, spill and grow" {
    const gpa = std.testing.allocator;
    var s: Scratch = .{};
    defer s.deinit(gpa);
    const m = s.mark();
    const a = s.bytes(gpa, 24);
    const b = s.bytes(gpa, 8);
    try std.testing.expectEqual(@as(usize, 32), @intFromPtr(b) - @intFromPtr(a));
    const big = s.bytes(gpa, Scratch.initial * 2);
    try std.testing.expectEqual(@as(usize, 1), s.spill.items.len);
    big[0] = 1;
    s.release(gpa, m);
    try std.testing.expectEqual(@as(usize, 0), s.spill.items.len);
    try std.testing.expect(s.buf.len >= Scratch.initial * 2);
}
