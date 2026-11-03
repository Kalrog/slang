//! Instruction-level tools of the hooked loop (see interp.fetch): both run
//! only when they are on, the plain loop never sees them.
//!
//! - `SLANG_TRACE=1` prints every instruction to stderr, `SLANG_TRACE=stack`
//!   also the frame's stack. The lines go through one buffer per VM, and a
//!   write that fails (the reader of a pipe went away) turns the trace off.
//! - `SLANG_OPSTATS=1` counts the instructions that run, by shape (the
//!   opcode, and for push, move and the fused forms where the result goes),
//!   and the pairs and triples of shapes that follow each other in one frame
//!   (a jump, call or return ends a run). The summary goes to stderr when the
//!   program ends: what a new fused form or a codegen change would cover.

const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const Thread = root.Thread;
const d = @import("disasm.zig");
const Op = d.Op;

pub const Tracer = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// SLANG_TRACE=stack: the values of the frame too
    stack: bool,
    buf: std.ArrayList(u8) = .empty,
    /// a write failed: no more lines
    off: bool = false,

    const flush_at = 64 * 1024;

    /// `mode` is the value of SLANG_TRACE.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, mode: []const u8) *Tracer {
        const t = gpa.create(Tracer) catch oom();
        t.* = .{ .gpa = gpa, .io = io, .stack = std.mem.eql(u8, mode, "stack") };
        return t;
    }

    pub fn destroy(t: *Tracer) void {
        t.flush();
        t.buf.deinit(t.gpa);
        t.gpa.destroy(t);
    }

    pub fn instruction(t: *Tracer, th: *Thread, fi: usize, base: usize, pc: usize, ins: u32) void {
        if (t.off) return;
        var line: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&line);
        w.print("[{d}] base={d} top={d} pc={d}: ", .{ fi, base, th.top, pc }) catch {};
        d.writeInstruction(&w, ins) catch {};
        if (t.stack) {
            w.writeAll("  stack:") catch {};
            var i = base;
            while (i < th.top and i < base + 12) : (i += 1) {
                w.writeByte(' ') catch {};
                var vb: [40]u8 = undefined;
                var vw: std.Io.Writer = .fixed(&vb);
                root.format.writeValue(&vw, th.stack[i]) catch {};
                w.writeAll(vw.buffered()) catch {};
            }
        }
        w.writeByte('\n') catch {};
        t.buf.appendSlice(t.gpa, w.buffered()) catch oom();
        if (t.buf.items.len >= flush_at) t.flush();
    }

    pub fn flush(t: *Tracer) void {
        if (t.buf.items.len == 0) return;
        defer t.buf.clearRetainingCapacity();
        if (t.off) return;
        var eb: [256]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(t.io, &eb);
        ew.interface.writeAll(t.buf.items) catch {
            t.off = true;
            return;
        };
        ew.interface.flush() catch {
            t.off = true;
        };
    }
};

/// An instruction's shape: its opcode and a variant (see variantOf).
const variants = 3;
const shapes = 64 * variants;

pub const OpStats = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ops: [shapes]u64 = @splat(0),
    /// pairs[a * shapes + b]: shape b right after shape a
    pairs: []u64,
    /// a << 16 | b << 8 | c
    triples: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    // the straight run the last instructions belong to
    last_th: ?*Thread = null,
    last_fi: usize = 0,
    last_pc: usize = 0,
    /// the shapes of the last two instructions of the run, and its length
    /// (up to 3)
    last: [2]u8 = .{ 0, 0 },
    run: u8 = 0,
    finished: bool = false,

    pub fn create(gpa: std.mem.Allocator, io: std.Io) *OpStats {
        const s = gpa.create(OpStats) catch oom();
        const pairs = gpa.alloc(u64, shapes * shapes) catch oom();
        @memset(pairs, 0);
        s.* = .{ .gpa = gpa, .io = io, .pairs = pairs };
        return s;
    }

    pub fn destroy(s: *OpStats) void {
        s.finish();
        s.triples.deinit(s.gpa);
        s.gpa.free(s.pairs);
        s.gpa.destroy(s);
    }

    /// 1: the value goes to or comes from the stack (push -1, move to the
    /// top, a fused form's push destination), 2: a setX that keeps its
    /// table on the stack, 0: anything else
    fn variantOf(op: Op, ins: u32) u8 {
        return switch (op) {
            .push, .move => if (d.argSBx(ins) < 0) 1 else 0,
            .add_x, .sub_x, .mul_x, .div_x, .mod_x, .get_x, .set_x => switch (d.argA(ins)) {
                d.push_dest => 1,
                d.peek_dest => 2,
                else => 0,
            },
            else => 0,
        };
    }

    pub fn record(s: *OpStats, th: *Thread, fi: usize, pc: usize, ins: u32) void {
        const op = d.opOf(ins);
        const shape: u8 = @intCast(@as(usize, @intFromEnum(op)) * variants + variantOf(op, ins));
        s.ops[shape] += 1;
        const follows = s.last_th == th and s.last_fi == fi and s.last_pc + 1 == pc;
        if (!follows) s.run = 0;
        if (s.run >= 1) s.pairs[@as(usize, s.last[1]) * shapes + shape] += 1;
        if (s.run >= 2) {
            const key = @as(u32, s.last[0]) << 16 | @as(u32, s.last[1]) << 8 | shape;
            const gop = s.triples.getOrPut(s.gpa, key) catch oom();
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        s.last = .{ s.last[1], shape };
        if (s.run < 3) s.run += 1;
        s.last_th = th;
        s.last_fi = fi;
        s.last_pc = pc;
    }

    fn writeShape(w: *std.Io.Writer, shape: u8) void {
        const op: Op = @enumFromInt(shape / variants);
        const v = shape % variants;
        w.writeAll(op.name()) catch {};
        const suffix: []const u8 = switch (op) {
            .push, .move => if (v == 1) " stack" else " r",
            .add_x, .sub_x, .mul_x, .div_x, .mod_x, .get_x, .set_x => switch (v) {
                1 => " push",
                2 => " peek",
                else => " r",
            },
            else => "",
        };
        w.writeAll(suffix) catch {};
    }

    const Entry = struct { key: u32, n: u64 };

    fn byCount(_: void, a: Entry, b: Entry) bool {
        return a.n > b.n;
    }

    fn section(w: *std.Io.Writer, title: []const u8, list: []Entry, total: u64, len: usize, top: usize) void {
        std.mem.sort(Entry, list, {}, byCount);
        w.print("\n{s}\n", .{title}) catch {};
        for (list[0..@min(list.len, top)]) |e| {
            const pct = @as(f64, @floatFromInt(e.n)) * 100.0 / @as(f64, @floatFromInt(@max(total, 1)));
            w.print("{d:>12} {d:>5.1}%  ", .{ e.n, pct }) catch {};
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                writeShape(w, @intCast((e.key >> @intCast(i * 8)) & 0xff));
                if (i > 0) w.writeAll(" ; ") catch {};
            }
            w.writeByte('\n') catch {};
        }
    }

    /// Writes the summary to stderr (once).
    pub fn finish(s: *OpStats) void {
        if (s.finished) return;
        s.finished = true;
        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(s.gpa);
        var total: u64 = 0;
        for (s.ops) |n| total += n;

        var eb: [4096]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(s.io, &eb);
        const w = &ew.interface;
        w.print("opstats: {d} instructions\n", .{total}) catch {};

        for (s.ops, 0..) |n, i| {
            if (n > 0) list.append(s.gpa, .{ .key = @intCast(i), .n = n }) catch oom();
        }
        section(w, "instructions", list.items, total, 1, 40);
        list.clearRetainingCapacity();
        for (s.pairs, 0..) |n, i| {
            const a = i / shapes;
            const b = i % shapes;
            if (n > 0) list.append(s.gpa, .{ .key = @intCast(a << 8 | b), .n = n }) catch oom();
        }
        section(w, "pairs (in one frame, in order)", list.items, total, 2, 40);
        list.clearRetainingCapacity();
        var it = s.triples.iterator();
        while (it.next()) |e| list.append(s.gpa, .{ .key = e.key_ptr.*, .n = e.value_ptr.* }) catch oom();
        section(w, "triples", list.items, total, 3, 30);
        w.flush() catch {};
    }
};
