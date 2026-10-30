//! A sampling profiler (`slang run --profile out.folded`, SLANG_PROFILE).
//!
//! While it is on, a timer thread counts milliseconds in an atomic, and the
//! interpreter runs its hooked loop: at every instruction, and after every
//! native call (before its frame is popped, so the time is the native's), it
//! looks at the count and, when ticks are pending, records the running
//! thread's stack for them. Samples are taken where the time went, not where
//! the checks happen to be.
//!
//! Frames are named by the function's name and where it is defined
//! (`seq_list (slang/peg:612)`, the line of its first instruction; `<func>`
//! when the definition gives no name) or `[native name]`. The result is written as
//! folded stacks (one `frame;frame;frame microseconds` per line, what
//! speedscope and the flame graph tools read) and summarised on stderr: the
//! functions with the most self time and the most total time.

const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const Thread = root.Thread;
const Frame = @import("thread.zig").Frame;

pub const Profiler = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []u8,
    /// milliseconds the timer counted that no sample has taken yet
    pending: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    timer: ?std.Thread = null,
    /// folded stack -> microseconds
    stacks: std.StringHashMapUnmanaged(u64) = .empty,
    finished: bool = false,
    buf: std.ArrayList(u8) = .empty,

    pub const interval_ms = 1;

    pub fn create(gpa: std.mem.Allocator, io: std.Io, path: []const u8) *Profiler {
        const p = gpa.create(Profiler) catch oom();
        p.* = .{
            .gpa = gpa,
            .io = io,
            .path = gpa.dupe(u8, path) catch oom(),
        };
        p.timer = std.Thread.spawn(.{}, timerLoop, .{p}) catch null;
        return p;
    }

    fn timerLoop(p: *Profiler) void {
        while (!p.stop.load(.monotonic)) {
            p.io.sleep(.fromMilliseconds(interval_ms), .awake) catch {};
            _ = p.pending.fetchAdd(1, .monotonic);
        }
    }

    pub fn destroy(p: *Profiler) void {
        var it = p.stacks.keyIterator();
        while (it.next()) |k| p.gpa.free(k.*);
        p.stacks.deinit(p.gpa);
        p.buf.deinit(p.gpa);
        p.gpa.free(p.path);
        p.gpa.destroy(p);
    }

    /// Called at every instruction of the hooked loop and after native calls.
    pub inline fn check(p: *Profiler, th: *Thread) void {
        if (p.pending.load(.monotonic) == 0) return;
        const n = p.pending.swap(0, .monotonic);
        p.sample(th, @as(u64, n) * interval_ms * 1000);
    }

    fn writeFrame(w: *std.ArrayList(u8), gpa: std.mem.Allocator, fr: Frame) void {
        const p = fr.cl.proto orelse {
            w.print(gpa, "[native {s}]", .{fr.cl.nameBytes()}) catch oom();
            return;
        };
        const name = if (p.name) |n| n.bytes() else "<func>";
        if (p.locs.len > 0) {
            const l = p.locs[0];
            w.print(gpa, "{s} ({s}:{d})", .{ name, l.origin.bytes(), l.line }) catch oom();
        } else {
            w.appendSlice(gpa, name) catch oom();
        }
    }

    fn sample(p: *Profiler, th: *Thread, us: u64) void {
        p.buf.clearRetainingCapacity();
        for (th.frames.items, 0..) |fr, i| {
            if (i > 0) p.buf.append(p.gpa, ';') catch oom();
            writeFrame(&p.buf, p.gpa, fr);
        }
        if (p.buf.items.len == 0) return;
        const gop = p.stacks.getOrPut(p.gpa, p.buf.items) catch oom();
        if (!gop.found_existing) {
            gop.key_ptr.* = p.gpa.dupe(u8, p.buf.items) catch oom();
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += us;
    }

    const Entry = struct { name: []const u8, self: u64 = 0, total: u64 = 0 };

    fn bySelf(_: void, a: Entry, b: Entry) bool {
        return a.self > b.self;
    }

    fn byTotal(_: void, a: Entry, b: Entry) bool {
        return a.total > b.total;
    }

    /// Writes the folded stacks to the file and the summary to stderr (once).
    pub fn finish(p: *Profiler) void {
        if (p.finished) return;
        p.finished = true;
        p.stop.store(true, .monotonic);
        if (p.timer) |tm| tm.join();
        p.timer = null;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(p.gpa);
        var entries: std.StringHashMapUnmanaged(Entry) = .empty;
        defer entries.deinit(p.gpa);
        var all: u64 = 0;
        var frames: std.ArrayList([]const u8) = .empty;
        defer frames.deinit(p.gpa);
        var it = p.stacks.iterator();
        while (it.next()) |e| {
            const us = e.value_ptr.*;
            all += us;
            out.print(p.gpa, "{s} {d}\n", .{ e.key_ptr.*, us }) catch oom();
            frames.clearRetainingCapacity();
            var parts = std.mem.splitScalar(u8, e.key_ptr.*, ';');
            while (parts.next()) |f| frames.append(p.gpa, f) catch oom();
            for (frames.items, 0..) |f, i| {
                // a function counts once per stack for its total (recursion)
                var seen = false;
                for (frames.items[0..i]) |g| {
                    if (std.mem.eql(u8, f, g)) seen = true;
                }
                const gop = entries.getOrPut(p.gpa, f) catch oom();
                if (!gop.found_existing) gop.value_ptr.* = .{ .name = f };
                if (!seen) gop.value_ptr.total += us;
                if (i == frames.items.len - 1) gop.value_ptr.self += us;
            }
        }
        std.Io.Dir.cwd().writeFile(p.io, .{ .sub_path = p.path, .data = out.items }) catch {};

        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(p.gpa);
        var eit = entries.valueIterator();
        while (eit.next()) |v| list.append(p.gpa, v.*) catch oom();

        var eb: [4096]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(p.io, &eb);
        const w = &ew.interface;
        w.print("profile: {d} ms sampled, folded stacks in {s}\n", .{ all / 1000, p.path }) catch {};
        const top = @min(list.items.len, 25);
        std.mem.sort(Entry, list.items, {}, bySelf);
        w.writeAll("\n  self ms     %  function\n") catch {};
        for (list.items[0..top]) |e| summaryLine(w, e.self, all, e.name);
        std.mem.sort(Entry, list.items, {}, byTotal);
        w.writeAll("\n total ms     %  function\n") catch {};
        for (list.items[0..top]) |e| summaryLine(w, e.total, all, e.name);
        w.flush() catch {};
    }

    fn summaryLine(w: *std.Io.Writer, us: u64, all: u64, name: []const u8) void {
        const pct: f64 = if (all == 0) 0 else @as(f64, @floatFromInt(us)) * 100.0 / @as(f64, @floatFromInt(all));
        w.print("{d:>8.1} {d:>5.1}  {s}\n", .{ @as(f64, @floatFromInt(us)) / 1000.0, pct, name }) catch {};
    }
};
