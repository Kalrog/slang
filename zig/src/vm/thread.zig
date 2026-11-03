const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const VM = root.VM;
const Value = root.Value;
const Table = root.Table;
const String = root.String;
const object = @import("object.zig");
const Object = object.Object;
const Closure = object.Closure;
const Upvalue = object.Upvalue;
const Proto = object.Proto;
const Error = root.Error;
const Location = root.Location;
const interp = @import("interp.zig");
const gc = @import("gc.zig");

/// Status of a coroutine.
pub const Status = enum(u8) {
    init,
    running,
    suspended,
    dead,

    pub fn name(s: Status) []const u8 {
        return @tagName(s);
    }
};

/// One activation record. base is the stack index of the first
/// argument/local; the callee itself sits at base-1 and receives the result.
pub const Frame = struct {
    cl: *Closure,
    pc: u32,
    base: u32,
    protected: bool,
    /// where the result goes when the frame returns: pushed where the
    /// function was (dest_push), dropped (a setter's, dest_drop) or into
    /// the caller's register dest (a getter's, for get_x)
    dest: u16 = dest_push,
    /// how many arguments the call passed (slang/vm's arg_count): with
    /// trailing nulls, which a rest parameter cannot hold
    nargs: u32 = 0,
};

pub const dest_push: u16 = 0xFFFF;
pub const dest_drop: u16 = 0xFFFE;

/// A try (or a defer's protected region) in progress: an error raised while
/// it is the innermost one goes to pc in frame `frame`, with the stack cut
/// back to top and upvalues from close_from closed.
pub const Handler = struct {
    frame: u32,
    pc: u32,
    top: u32,
    close_from: u32,
};

/// An execution context (the main thread or a coroutine) with its own value
/// stack and frame stack.
pub const Thread = struct {
    obj: Object,
    vm: *VM,
    id: u32,
    stack: []Value,
    top: usize = 0,
    frames: std.ArrayList(Frame) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    open_upvals: std.ArrayList(*Upvalue) = .empty,
    status: Status = .init,
    entry: ?*Closure,
    run_depth: u32 = 0,
    yielded: Value = .null,
    is_main: bool = false,
    /// temporary memory of the C calls made on this thread (slang/ffi)
    scratch: root.Scratch = .{},

    pub const initial_stack = 256;
    pub const max_stack = 1 << 24;
    pub const max_frames = 1 << 20;

    pub fn init(vm: *VM, id: u32, entry: ?*Closure) Thread {
        const stack = vm.gpa.alloc(Value, initial_stack) catch oom();
        @memset(stack, .null);
        return .{ .obj = .{ .kind = .thread }, .vm = vm, .id = id, .stack = stack, .entry = entry };
    }

    pub fn deinit(th: *Thread) void {
        th.vm.gpa.free(th.stack);
        th.frames.deinit(th.vm.gpa);
        th.handlers.deinit(th.vm.gpa);
        th.open_upvals.deinit(th.vm.gpa);
        th.scratch.deinit(th.vm.gpa);
    }

    pub fn depth(th: *const Thread) usize {
        return th.frames.items.len;
    }

    pub inline fn push(th: *Thread, v: Value) void {
        if (th.top == th.stack.len) th.grow(th.top + 1) catch @panic("stack overflow");
        th.stack[th.top] = v;
        th.top += 1;
    }

    fn grow(th: *Thread, need: usize) Error!void {
        var n = th.stack.len * 2;
        while (n < need) n *= 2;
        if (n > max_stack) return th.vm.raise("stack overflow", .{});
        const old_len = th.stack.len;
        th.stack = th.vm.gpa.realloc(th.stack, n) catch oom();
        @memset(th.stack[old_len..], .null);
    }

    /// Makes sure the stack can hold `need` values. May move the stack.
    pub fn ensure(th: *Thread, need: usize) Error!void {
        if (need > th.stack.len) try th.grow(need);
    }

    /// The closure of the innermost frame (for natives reading their nvals).
    pub fn currentClosure(th: *const Thread) *Closure {
        th.assertNativeFrame();
        return th.frames.items[th.frames.items.len - 1].cl;
    }

    /// Argument i of the running native, read from the stack (valid even
    /// after a call back into the VM moved the stack).
    pub fn arg(th: *const Thread, i: usize) Value {
        th.assertNativeFrame();
        const fr = th.frames.items[th.frames.items.len - 1];
        const idx = fr.base + i;
        if (idx >= th.top) return .null;
        return th.stack[idx];
    }

    pub fn nargs(th: *const Thread) usize {
        th.assertNativeFrame();
        const fr = th.frames.items[th.frames.items.len - 1];
        return th.top - fr.base;
    }

    /// A native marked frameless (stdlib.Native) that reads its frame would
    /// read its caller's: the checked builds catch it here.
    inline fn assertNativeFrame(th: *const Thread) void {
        const n = th.frames.items.len;
        std.debug.assert(n > 0 and th.frames.items[n - 1].cl.proto == null);
    }

    fn pushFrame(th: *Thread, cl: *Closure, base: usize, protected: bool) Error!void {
        if (th.frames.items.len >= max_frames) return th.vm.raise("stack overflow (too many nested calls)", .{});
        th.frames.append(th.vm.gpa, .{ .cl = cl, .pc = 0, .base = @intCast(base), .protected = protected }) catch oom();
    }

    pub fn popFrame(th: *Thread) void {
        const fr = th.frames.pop().?;
        if (fr.cl.proto != null) th.closeUpvalues(fr.base);
        // the frame's handlers end with it (a return from inside a try)
        const n = th.frames.items.len;
        while (th.handlers.items.len > 0 and th.handlers.items[th.handlers.items.len - 1].frame >= n) {
            _ = th.handlers.pop();
        }
    }

    pub fn pushHandler(th: *Thread, h: Handler) void {
        th.handlers.append(th.vm.gpa, h) catch oom();
    }

    fn findOrCreateUpvalue(th: *Thread, idx: usize) *Upvalue {
        const ups = th.open_upvals.items;
        var i: usize = ups.len;
        while (i > 0) {
            i -= 1;
            if (ups[i].idx == idx) return ups[i];
            if (ups[i].idx < idx) {
                i += 1;
                break;
            }
        }
        const u = th.vm.newOpenUpvalue(th, idx);
        th.open_upvals.insert(th.vm.gpa, i, u) catch oom();
        return u;
    }

    pub fn closeUpvalues(th: *Thread, from: usize) void {
        var ups = &th.open_upvals;
        while (ups.items.len > 0 and ups.items[ups.items.len - 1].idx >= from) {
            const u = ups.pop().?;
            u.close();
            // the value leaves the stack for the upvalue (see gc.zig)
            gc.barrier(th.vm, &u.obj, u.v);
        }
    }

    pub fn makeClosure(th: *Thread, fr: Frame, child: *Proto) *Closure {
        const cl = th.vm.newClosure(child);
        for (child.upvals, 0..) |uv, i| {
            if (uv.is_local) {
                cl.upvals[i] = th.findOrCreateUpvalue(fr.base + uv.index);
            } else if (uv.index < fr.cl.upvals.len) {
                cl.upvals[i] = fr.cl.upvals[uv.index];
            } else {
                cl.upvals[i] = th.vm.newUpvalue(.null);
            }
        }
        return cl;
    }

    /// Invokes f with args from native code and returns its result. `args`
    /// may alias the stack; it is copied before the stack can move.
    pub fn call(th: *Thread, f: Value, args: []const Value) Error!Value {
        var small: [16]Value = undefined;
        const copy: []Value = if (args.len <= small.len) small[0..args.len] else th.vm.gpa.alloc(Value, args.len) catch oom();
        defer if (args.len > small.len) th.vm.gpa.free(copy);
        @memcpy(copy, args);

        const fn_idx = th.top;
        try th.ensure(fn_idx + 1 + copy.len + 8);
        th.push(f);
        for (copy) |a| th.push(a);
        const is_slang = th.precall(fn_idx, copy.len, false) catch |e| {
            th.top = fn_idx;
            if (e == error.Yield) {
                th.popFrame();
                th.vm.setError("attempt to yield across a native call boundary", .{});
                th.fillError();
                return error.Slang;
            }
            return e;
        };
        if (is_slang) {
            th.run(th.frames.items.len - 1) catch |e| {
                th.top = fn_idx;
                return e;
            };
        }
        const res = th.stack[fn_idx];
        th.top = fn_idx;
        return res;
    }

    /// Calls the function at fn_idx with the nargs values above it, leaving
    /// the result at fn_idx (top becomes fn_idx + 1). On failure the stack
    /// is cut back to fn_idx.
    pub fn callInPlace(th: *Thread, fn_idx: usize, nargs_: usize) Error!void {
        const is_slang = th.precall(fn_idx, nargs_, false) catch |e| {
            th.top = fn_idx;
            if (e == error.Yield) {
                th.popFrame();
                th.vm.setError("attempt to yield across a native call boundary", .{});
                th.fillError();
                return error.Slang;
            }
            return e;
        };
        if (is_slang) {
            th.run(th.frames.items.len - 1) catch |e| {
                th.top = fn_idx;
                return e;
            };
        }
    }

    /// Sets up a call of the value at fn_idx with nargs arguments above it.
    /// Native functions are executed immediately and their result replaces
    /// the callee slot; for slang functions a frame is pushed and true is
    /// returned.
    pub fn precall(th: *Thread, fn_idx: usize, nargs_: usize, protected: bool) Error!bool {
        const f = th.stack[fn_idx];
        const cl: *Closure = switch (f) {
            .function => |c| c,
            else => {
                if (interp.metaOf(f)) |m| {
                    const c = m.getName("__call");
                    if (c == .function) {
                        // call __call(f, args...): shift the arguments up by one slot
                        th.push(.null);
                        std.mem.copyBackwards(Value, th.stack[fn_idx + 1 .. th.top], th.stack[fn_idx .. th.top - 1]);
                        th.stack[fn_idx] = c;
                        return th.precall(fn_idx, nargs_ + 1, protected);
                    }
                }
                return th.vm.raise("attempt to call a {s} value", .{f.typeName()});
            },
        };
        if (cl.special != .none) {
            if (cl.special == .pcall) {
                if (nargs_ < 1) return th.vm.raise("pcall requires at least one argument", .{});
                std.mem.copyForwards(Value, th.stack[fn_idx .. th.top - 1], th.stack[fn_idx + 1 .. th.top]);
                th.top -= 1;
                return th.precall(fn_idx, nargs_ - 1, true);
            }
            // frameless, unless the profiler wants the frame to sample
            if (th.vm.profiler == null) return th.callFrameless(cl, fn_idx, protected);
        }
        if (cl.native) |native| {
            try th.pushFrame(cl, fn_idx + 1, protected);
            const res = native(th, th.stack[fn_idx + 1 .. th.top]) catch |e| {
                if (e == error.Yield) return error.Yield;
                th.fillError();
                th.popFrame();
                if (protected) {
                    th.top = fn_idx;
                    const r = th.errResult();
                    th.push(r);
                    return false;
                }
                return error.Slang;
            };
            // (sampled with the native's frame on the stack: its time is its own)
            if (th.vm.profiler) |prof| prof.check(th);
            th.popFrame();
            th.top = fn_idx;
            if (protected) {
                const r = th.okResult(res);
                th.push(r);
            } else {
                th.push(res);
            }
            return false;
        }
        const p = cl.proto.?;
        const base = fn_idx + 1;
        var nparams: usize = p.nargs;
        if (p.is_vararg) nparams -= 1;
        try th.ensure(base + @max(nparams + 1, p.max_stack) + 8);
        if (nargs_ > nparams) {
            if (p.is_vararg) {
                // the extra arguments by position: a null one is a gap
                const extra = th.vm.newTable(nargs_ - nparams, 0);
                for (th.stack[base + nparams .. base + nargs_], 0..) |v, i| extra.set(th.vm.gpa, .{ .int = @intCast(i) }, v);
                th.stack[base + nparams] = .{ .table = extra };
                th.top = base + nparams + 1;
            } else {
                th.top = base + nparams;
            }
        } else {
            // (ensure above made room for the parameters and max_stack)
            if (th.top < base + nparams) {
                @memset(th.stack[th.top .. base + nparams], .null);
                th.top = base + nparams;
            }
            if (p.is_vararg) th.push(.{ .table = th.vm.newTable(0, 0) });
        }
        const need = base + p.max_stack;
        if (th.top < need) {
            @memset(th.stack[th.top..need], .null);
            th.top = need;
        }
        try th.pushFrame(cl, base, protected);
        th.frames.items[th.frames.items.len - 1].nargs = @intCast(nargs_);
        return true;
    }

    /// A native marked frameless: called on the arguments as they are on
    /// the stack, with a frame made up only for an error's traceback (or
    /// a yield, which the resume expects to pop).
    fn callFrameless(th: *Thread, cl: *Closure, fn_idx: usize, protected: bool) Error!bool {
        const res = cl.native.?(th, th.stack[fn_idx + 1 .. th.top]) catch |e| {
            th.frames.append(th.vm.gpa, .{ .cl = cl, .pc = 0, .base = @intCast(fn_idx + 1), .protected = protected }) catch oom();
            if (e == error.Yield) return error.Yield;
            th.fillError();
            th.popFrame();
            if (protected) {
                th.top = fn_idx;
                const r = th.errResult();
                th.push(r);
                return false;
            }
            return error.Slang;
        };
        th.top = fn_idx;
        if (protected) {
            const r = th.okResult(res);
            th.push(r);
        } else {
            th.push(res);
        }
        return false;
    }

    pub fn run(th: *Thread, stop_depth: usize) Error!void {
        return interp.run(th, stop_depth);
    }

    // Operations with metamethod support, implemented in interp.zig.
    pub const arithMeta = interp.ThreadOps.arithMeta;
    pub const getTable = interp.ThreadOps.getTable;
    pub const setTable = interp.ThreadOps.setTable;
    pub const rawSet = interp.ThreadOps.rawSet;
    pub const setMeta = interp.ThreadOps.setMeta;
    pub const equal = interp.ThreadOps.equal;
    pub const lessThan = interp.ThreadOps.lessThan;
    pub const typeOf = interp.ThreadOps.typeOf;
    pub const toString = interp.ThreadOps.toString;
    pub const renderString = interp.ThreadOps.renderString;
    pub const len = interp.ThreadOps.len;

    fn okResult(th: *Thread, v: Value) Value {
        const t = th.vm.newTable(2, 0);
        t.append(th.vm.gpa, th.vm.str("ok"));
        t.append(th.vm.gpa, v);
        return .{ .table = t };
    }

    fn errResult(th: *Thread) Value {
        const e = th.vm.errorToValue();
        const t = th.vm.newTable(2, 0);
        t.append(th.vm.gpa, th.vm.str("err"));
        t.append(th.vm.gpa, e);
        return .{ .table = t };
    }

    /// Completes the pending error with the current location and traceback
    /// if the creator did not set them.
    pub fn fillError(th: *Thread) void {
        const vm = th.vm;
        if (vm.err == null) vm.setError("unknown error", .{});
        const e = &vm.err.?;
        if (e.loc == null) e.loc = th.currentLocation();
        if (e.trace == null) e.trace = th.traceback();
    }

    /// The source position of the innermost slang frame.
    pub fn currentLocation(th: *const Thread) ?Location {
        var i = th.frames.items.len;
        while (i > 0) {
            i -= 1;
            const fr = th.frames.items[i];
            const p = fr.cl.proto orelse continue;
            const pc: usize = if (fr.pc > 0) fr.pc - 1 else 0;
            const l = p.location(pc) orelse return null;
            return .{
                .origin = th.vm.gpa.dupe(u8, l.origin.bytes()) catch oom(),
                .line = l.line,
                .column = l.column,
            };
        }
        return null;
    }

    /// Renders the frame stack, innermost first: `name (origin:line:column)`
    /// for a function with a name, the position alone otherwise.
    pub fn traceback(th: *const Thread) []u8 {
        var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("stack traceback:") catch oom();
        var i = th.frames.items.len;
        while (i > 0) {
            i -= 1;
            const fr = th.frames.items[i];
            w.writeAll("\n  at ") catch oom();
            const p = fr.cl.proto orelse {
                w.print("[native {s}]", .{fr.cl.nameBytes()}) catch oom();
                continue;
            };
            const pc: usize = if (fr.pc > 0) fr.pc - 1 else 0;
            if (p.location(pc)) |l| {
                if (p.name) |n| {
                    w.print("{s} ({s}:{d}:{d})", .{ n.bytes(), l.origin.bytes(), l.line, l.column }) catch oom();
                } else {
                    w.print("{s}:{d}:{d}", .{ l.origin.bytes(), l.line, l.column }) catch oom();
                }
            } else if (p.name) |n| {
                w.print("{s} (no source info)", .{n.bytes()}) catch oom();
            } else {
                w.writeAll("function (no source info)") catch oom();
            }
        }
        return aw.toOwnedSlice() catch oom();
    }

    /// Deals with an error raised inside run: either transfers control to the
    /// nearest protected call of this run loop (returns normally) or unwinds
    /// the loop's frames and returns the error to the caller.
    pub fn handleError(th: *Thread, err: Error, stop_depth: usize) Error!void {
        if (err == error.Yield) {
            if (th.run_depth == 1 and !th.is_main) return error.Yield;
            th.popFrame();
            th.vm.setError("attempt to yield across a native call boundary", .{});
        }
        th.fillError();
        // an error nothing will catch stops the debugger before the unwinding
        if (th.vm.debugger) |dbg| dbg.raised(th);
        var i = th.frames.items.len;
        // a killed isolate unwinds past every try and pcall
        if (th.vm.interrupt.load(.monotonic)) i = stop_depth;
        while (i > stop_depth) {
            i -= 1;
            // a try in this frame catches before the frame's own protection
            // (a pcall of the function) does
            const hs = th.handlers.items;
            if (hs.len > 0 and hs[hs.len - 1].frame == i) {
                const h = th.handlers.pop().?;
                while (th.frames.items.len > i + 1) th.popFrame();
                th.closeUpvalues(h.close_from);
                th.top = h.top;
                th.frames.items[i].pc = h.pc;
                const v = th.vm.errorToValue();
                th.push(v);
                return;
            }
            if (th.frames.items[i].protected) {
                const fn_idx = th.frames.items[i].base - 1;
                while (th.frames.items.len > i) th.popFrame();
                th.top = fn_idx;
                const r = th.errResult();
                th.push(r);
                return;
            }
        }
        while (th.frames.items.len > stop_depth) th.popFrame();
        return error.Slang;
    }

    /// Runs a coroutine until it yields or finishes. The returned value is the
    /// yielded value or the function result. Resuming a dead coroutine
    /// returns null.
    pub fn resumeCo(co: *Thread, args: []const Value) Error!Value {
        switch (co.status) {
            .dead => return .null,
            .running => return co.vm.raise("cannot resume a running coroutine", .{}),
            .init => {
                co.status = .running;
                co.top = 0;
                try co.ensure(1 + args.len + 8);
                co.push(.{ .function = co.entry.? });
                for (args) |a| co.push(a);
                const is_slang = co.precall(0, args.len, false) catch |e| return co.finish(e);
                if (!is_slang) return co.finish(null);
            },
            .suspended => {
                co.status = .running;
                const fr = co.frames.items[co.frames.items.len - 1];
                const fn_idx = fr.base - 1;
                co.popFrame();
                co.top = fn_idx;
                co.push(if (args.len > 0) args[0] else .null);
            },
        }
        co.run(0) catch |e| return co.finish(e);
        return co.finish(null);
    }

    fn finish(co: *Thread, err: ?Error) Error!Value {
        if (err) |e| {
            if (e == error.Yield) {
                co.status = .suspended;
                const v = co.yielded;
                co.yielded = .null;
                return v;
            }
            co.status = .dead;
            while (co.frames.items.len > 0) co.popFrame();
            co.top = 0;
            return e;
        }
        co.status = .dead;
        const res: Value = if (co.top > 0) co.stack[co.top - 1] else .null;
        co.top = 0;
        return res;
    }

    /// Suspends the current coroutine with v. The native returns this error.
    pub fn yield(th: *Thread, v: Value) Error {
        if (th.is_main) return th.vm.raise("cannot yield from the main thread", .{});
        th.yielded = v;
        return error.Yield;
    }
};
