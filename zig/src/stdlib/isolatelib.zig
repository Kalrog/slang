//! slang/isolate: parallelism without shared state. An isolate is a VM of
//! its own (heap, collector, globals, module cache) on an OS thread of its
//! own; isolates talk through channels, which copy what is sent.
//!
//! Channels, isolates and messages live outside every VM, in memory that is
//! reference counted across them: a VM sees a channel or an isolate through
//! a userdata handle that holds one reference. A message is a value
//! serialized into a neutral byte form plus the channels and isolates it
//! carries; receiving it builds the value again in the receiving heap, so no
//! VM ever touches another's objects.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Closure = vm_mod.Closure;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const api = vm_mod.api;
const gc = vm_mod.gc;
const slb = vm_mod.slb;
const stdlib = @import("stdlib.zig");
const ffilib = @import("ffilib.zig");
const ctypes = @import("ctypes.zig");

/// Whether this build can run isolates (WebAssembly has no threads).
pub const supported = !builtin.single_threaded and !builtin.cpu.arch.isWasm();

/// Memory that outlives any one VM: channels, isolates, messages.
const shared = std.heap.c_allocator;

pub const channel_tname = "isolate.channel";
pub const isolate_tname = "isolate.isolate";

/// A table nested deeper than this is not sent (the encoder recurses).
const max_depth = 10000;

// ------------------------------------------------------------ process state

/// Isolates whose thread has not ended yet.
var running: std.atomic.Value(u32) = .init(0);
var next_id: std.atomic.Value(u32) = .init(1);
/// Isolates that failed and whose error nobody has joined yet (each holds a
/// reference): printed when the program ends.
var failed_lock: std.Io.Mutex = .init;
var failed: std.ArrayList(*Isolate) = .empty;

// ------------------------------------------------------------ waiting

/// A mutex and a condition that is broadcast on every change of what it
/// guards (a channel's queue, an isolate's state).
const Sync = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,

    fn lock(s: *Sync, io: std.Io) void {
        s.mutex.lockUncancelable(io);
    }

    fn unlock(s: *Sync, io: std.Io) void {
        s.mutex.unlock(io);
    }

    fn broadcast(s: *Sync, io: std.Io) void {
        s.cond.broadcast(io);
    }
};

fn currentIsolate(vm: *VM) ?*Isolate {
    return @ptrCast(@alignCast(vm.isolate));
}

/// Waits on s, whose mutex the caller holds, for its next broadcast.
/// Returns false when vm's isolate is being killed: kill() broadcasts the
/// Sync its target waits on (see Isolate.waiting).
fn wait(vm: *VM, s: *Sync) bool {
    const me = currentIsolate(vm);
    if (me) |m| m.waiting.store(s, .seq_cst);
    defer if (me) |m| m.waiting.store(null, .seq_cst);
    if (vm.interrupt.load(.seq_cst)) return false;
    s.cond.waitUncancelable(vm.io, &s.mutex);
    return !vm.interrupt.load(.seq_cst);
}

/// Around a blocking wait: C callbacks from other threads may run slang in
/// this VM meanwhile (see ffilib's lock), so the VM is not touched until
/// unblock.
fn block(vm: *VM, th: *Thread) bool {
    if (comptime build_options.ffi) return ffilib.release(vm, th);
    return false;
}

fn unblock(vm: *VM, released: bool) void {
    if (comptime build_options.ffi) {
        if (released) ffilib.reacquire(vm);
    }
}

fn killed(vm: *VM) Error {
    return vm.raise("isolate killed", .{});
}

// ------------------------------------------------------------ messages

/// What crosses by reference.
const Ref = union(enum) {
    channel: *Channel,
    isolate: *Isolate,
    shared: *ctypes.SharedMem,

    fn retain(r: Ref) void {
        switch (r) {
            inline else => |p| p.retain(),
        }
    }

    fn release(r: Ref) void {
        switch (r) {
            inline else => |p| p.release(),
        }
    }
};

/// Values in transit: bytes and the references they carry, each retained
/// by the message until it is freed.
pub const Message = struct {
    bytes: []u8 = &.{},
    refs: []Ref = &.{},

    pub fn deinit(m: *Message) void {
        for (m.refs) |r| r.release();
        shared.free(m.refs);
        shared.free(m.bytes);
        m.* = .{};
    }
};

const Tag = enum(u8) { null, false, true, int, float, string, table, table_ref, function, ref, buffer };

/// A message is u32 count, then count values:
///
///   value := tag payload
///   int i64, float f64, string (u32 len, bytes),
///   table (u32 narr, u32 nhash, u8 has_meta, [meta value], narr values,
///          nhash key/value pairs): numbered in the order they appear,
///   table_ref u32 (a table seen before in this message: cycles, sharing),
///   function (u32 len, .slb bytes), ref u32 (an index into refs),
///   buffer (u32 ref, u64 byte offset, u64 count, string element type): a
///   view of a shared buffer
const Encoder = struct {
    vm: *VM,
    out: std.Io.Writer.Allocating,
    refs: std.ArrayList(Ref) = .empty,
    tables: std.AutoHashMapUnmanaged(*Table, u32) = .empty,
    depth: u32 = 0,

    fn init(vm: *VM) Encoder {
        return .{ .vm = vm, .out = .init(shared) };
    }

    fn deinit(e: *Encoder) void {
        for (e.refs.items) |r| r.release();
        e.refs.deinit(shared);
        e.out.deinit();
        e.tables.deinit(e.vm.gpa);
    }

    fn finish(e: *Encoder) Message {
        const m: Message = .{
            .bytes = e.out.toOwnedSlice() catch oom(),
            .refs = e.refs.toOwnedSlice(shared) catch oom(),
        };
        e.tables.deinit(e.vm.gpa);
        return m;
    }

    fn tag(e: *Encoder, t: Tag) void {
        e.out.writer.writeByte(@intFromEnum(t)) catch oom();
    }

    fn int(e: *Encoder, comptime T: type, v: T) void {
        e.out.writer.writeInt(T, v, .little) catch oom();
    }

    fn bytes(e: *Encoder, b: []const u8) void {
        e.int(u32, @intCast(b.len));
        e.out.writer.writeAll(b) catch oom();
    }

    fn value(e: *Encoder, v: Value) Error!void {
        switch (v) {
            .null => e.tag(.null),
            .bool => |b| e.tag(if (b) .true else .false),
            .int => |i| {
                e.tag(.int);
                e.int(i64, i);
            },
            .float => |f| {
                e.tag(.float);
                e.int(u64, @bitCast(f));
            },
            .string => |s| {
                e.tag(.string);
                e.bytes(s.bytes());
            },
            .table => |t| try e.table(t),
            .function => |c| try e.function(c),
            .userdata => |u| try e.userdata(u),
            .thread => return e.vm.raise("cannot send a coroutine to another isolate", .{}),
        }
    }

    fn table(e: *Encoder, t: *Table) Error!void {
        const gop = e.tables.getOrPut(e.vm.gpa, t) catch oom();
        if (gop.found_existing) {
            e.tag(.table_ref);
            e.int(u32, gop.value_ptr.*);
            return;
        }
        gop.value_ptr.* = @intCast(e.tables.count() - 1);
        if (e.depth >= max_depth) return e.vm.raise("cannot send a table nested deeper than {d} levels", .{max_depth});
        e.depth += 1;
        defer e.depth -= 1;
        var nhash: u32 = 0;
        for (t.ents.items) |en| {
            if (en.key != .null) nhash += 1;
        }
        e.tag(.table);
        e.int(u32, @intCast(t.arr.items.len));
        e.int(u32, nhash);
        if (t.meta) |m| {
            e.out.writer.writeByte(1) catch oom();
            try e.table(m);
        } else {
            e.out.writer.writeByte(0) catch oom();
        }
        for (t.arr.items) |x| try e.value(x);
        for (t.ents.items) |en| {
            if (en.key == .null) continue;
            try e.value(en.key);
            try e.value(en.val);
        }
    }

    /// A function crosses as bytecode, loaded with the receiver's globals:
    /// it may use globals (its _ENV), never locals of the code around it.
    fn function(e: *Encoder, c: *Closure) Error!void {
        const p = c.proto orelse return e.vm.raise("cannot send the native function {s} to another isolate", .{c.nameBytes()});
        for (p.upvals) |u| {
            if (u.name.eqlBytes("_ENV")) continue;
            const name = if (p.name) |n| n.bytes() else "(anonymous)";
            return e.vm.raise("cannot send function {s} to another isolate: it uses {s} from the code around it (a function that crosses can use globals and what it requires itself)", .{ name, u.name.bytes() });
        }
        const code = slb.encode(e.vm.gpa, p, false);
        defer e.vm.gpa.free(code);
        e.tag(.function);
        e.bytes(code);
    }

    fn ref(e: *Encoder, r: Ref) u32 {
        r.retain();
        e.refs.append(shared, r) catch oom();
        return @intCast(e.refs.items.len - 1);
    }

    fn userdata(e: *Encoder, u: *Userdata) Error!void {
        if (ctypes.asBuffer(.{ .userdata = u })) |b| {
            const m = ctypes.sharedOf(b) orelse return e.vm.raise("cannot send a buffer to another isolate (only buffer.shared ones cross)", .{});
            const p = b.as(ctypes.Ptr);
            const name = ctypes.primitiveName(p.ty.?) orelse return e.vm.raise("cannot send a buffer of {s} to another isolate", .{p.ty.?.name});
            const idx = e.ref(.{ .shared = m });
            e.tag(.buffer);
            e.int(u32, idx);
            e.int(u64, p.addr - @intFromPtr(m.bytes.ptr));
            e.int(u64, p.count);
            e.bytes(std.mem.span(name));
            return;
        }
        const r: Ref = if (std.mem.eql(u8, u.tname, channel_tname))
            .{ .channel = u.as(*Channel).* }
        else if (std.mem.eql(u8, u.tname, isolate_tname))
            .{ .isolate = u.as(*Isolate).* }
        else
            return e.vm.raise("cannot send a {s} to another isolate", .{u.tname});
        const idx = e.ref(r);
        e.tag(.ref);
        e.int(u32, idx);
    }
};

/// Serializes values into a message, or raises for one that cannot cross.
pub fn encode(vm: *VM, values: []const Value) Error!Message {
    var e: Encoder = .init(vm);
    errdefer e.deinit();
    e.int(u32, @intCast(values.len));
    for (values) |v| try e.value(v);
    return e.finish();
}

/// Builds a message's values in vm's heap. The message stays valid (a
/// result is decoded once per join).
const Decoder = struct {
    vm: *VM,
    msg: *const Message,
    pos: usize = 0,
    tables: std.ArrayList(*Table) = .empty,

    fn take(d: *Decoder, n: usize) []const u8 {
        const b = d.msg.bytes[d.pos .. d.pos + n];
        d.pos += n;
        return b;
    }

    fn int(d: *Decoder, comptime T: type) T {
        return std.mem.readInt(T, d.take(@sizeOf(T))[0..@sizeOf(T)], .little);
    }

    fn bytes(d: *Decoder) []const u8 {
        return d.take(d.int(u32));
    }

    fn value(d: *Decoder) Error!Value {
        const vm = d.vm;
        const t: Tag = @enumFromInt(d.take(1)[0]);
        switch (t) {
            .null => return .null,
            .false => return .{ .bool = false },
            .true => return .{ .bool = true },
            .int => return .{ .int = d.int(i64) },
            .float => return .{ .float = @bitCast(d.int(u64)) },
            .string => return vm.str(d.bytes()),
            .table => {
                const narr = d.int(u32);
                const nhash = d.int(u32);
                const tbl = vm.newTable(narr, nhash);
                d.tables.append(vm.gpa, tbl) catch oom();
                if (d.take(1)[0] != 0) tbl.meta = (try d.value()).asTable();
                for (0..narr) |_| tbl.append(vm.gpa, try d.value());
                for (0..nhash) |_| {
                    const k = try d.value();
                    const v = try d.value();
                    tbl.set(vm.gpa, k, v);
                }
                return .{ .table = tbl };
            },
            .table_ref => return .{ .table = d.tables.items[d.int(u32)] },
            .function => {
                const p = slb.decode(vm, d.bytes()) catch |e| return vm.raise("{s}", .{slb.errorMessage(e)});
                return .{ .function = vm.load(p) };
            },
            .ref => return newHandle(vm, d.msg.refs[d.int(u32)]),
            .buffer => {
                const m = d.msg.refs[d.int(u32)].shared;
                const offset: usize = @intCast(d.int(u64));
                const count: usize = @intCast(d.int(u64));
                const ty = ctypes.primitive(d.bytes()).?;
                const root = ctypes.sharedBuffer(vm, m);
                if (offset == 0 and count == m.count and ty == m.ty) return .{ .userdata = root };
                return .{ .userdata = ctypes.sharedView(vm, root, @intFromPtr(m.bytes.ptr) + offset, ty, count) };
            },
        }
    }
};

/// Appends a message's values to out. Nothing collects meanwhile (only
/// the interpreter's safe points do), so the values need no rooting until
/// the caller hands them to slang.
pub fn decode(vm: *VM, msg: *const Message, out: *std.ArrayList(Value)) Error!void {
    var d: Decoder = .{ .vm = vm, .msg = msg };
    defer d.tables.deinit(vm.gpa);
    const n = d.int(u32);
    for (0..n) |_| out.append(vm.gpa, try d.value()) catch oom();
}

/// The first value of a message.
fn decodeOne(vm: *VM, msg: *const Message) Error!Value {
    var d: Decoder = .{ .vm = vm, .msg = msg };
    defer d.tables.deinit(vm.gpa);
    if (d.int(u32) == 0) return .null;
    return d.value();
}

// ------------------------------------------------------------ channels

/// Wakes an event loop when a channel changes (a uv async handle: see
/// watch); called with the channel's lock held, from any thread.
const Waker = struct {
    send: *const fn (?*anyopaque) callconv(.c) c_int,
    ctx: ?*anyopaque,
};

pub const Channel = struct {
    refs: std.atomic.Value(u32) = .init(1),
    sync: Sync = .{},
    queue: std.ArrayList(Message) = .empty,
    head: usize = 0,
    /// 0: unbounded
    capacity: usize = 0,
    closed: bool = false,
    wakers: std.ArrayList(Waker) = .empty,

    fn retain(c: *Channel) void {
        _ = c.refs.fetchAdd(1, .monotonic);
    }

    fn release(c: *Channel) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        for (c.queue.items[c.head..]) |*m| m.deinit();
        c.queue.deinit(shared);
        c.wakers.deinit(shared);
        shared.destroy(c);
    }

    fn count(c: *const Channel) usize {
        return c.queue.items.len - c.head;
    }

    fn full(c: *const Channel) bool {
        return c.capacity > 0 and c.count() >= c.capacity;
    }

    fn pop(c: *Channel) Message {
        const m = c.queue.items[c.head];
        c.head += 1;
        if (c.head == c.queue.items.len) {
            c.queue.clearRetainingCapacity();
            c.head = 0;
        } else if (c.head >= 64 and c.head * 2 >= c.queue.items.len) {
            const rest = c.queue.items.len - c.head;
            std.mem.copyForwards(Message, c.queue.items[0..rest], c.queue.items[c.head..]);
            c.queue.shrinkRetainingCapacity(rest);
            c.head = 0;
        }
        return m;
    }

    /// After a change, with the lock held: blocked receivers and senders
    /// re-check, watching loops are woken.
    fn changed(c: *Channel, io: std.Io) void {
        c.sync.broadcast(io);
        for (c.wakers.items) |w| _ = w.send(w.ctx);
    }

    const PutResult = enum { ok, full, closed, killed };

    fn put(c: *Channel, th: *Thread, msg: Message, blocking: bool) PutResult {
        const vm = th.vm;
        const rel = block(vm, th);
        defer unblock(vm, rel);
        c.sync.lock(vm.io);
        defer c.sync.unlock(vm.io);
        while (true) {
            if (c.closed) return .closed;
            if (!c.full()) break;
            if (!blocking) return .full;
            if (!wait(vm, &c.sync)) return .killed;
        }
        c.queue.append(shared, msg) catch oom();
        c.changed(vm.io);
        return .ok;
    }

    const TakeResult = union(enum) { msg: Message, empty, closed, killed };

    fn take(c: *Channel, th: *Thread, blocking: bool) TakeResult {
        const vm = th.vm;
        const rel = block(vm, th);
        defer unblock(vm, rel);
        c.sync.lock(vm.io);
        defer c.sync.unlock(vm.io);
        while (c.count() == 0) {
            if (c.closed) return .closed;
            if (!blocking) return .empty;
            if (!wait(vm, &c.sync)) return .killed;
        }
        const m = c.pop();
        c.changed(vm.io);
        return .{ .msg = m };
    }
};

// ------------------------------------------------------------ isolates

pub const Isolate = struct {
    refs: std.atomic.Value(u32) = .init(1),
    sync: Sync = .{},
    id: u32,
    state: State = .running,
    /// the isolate's VM while its thread runs it (guarded by sync)
    vm: ?*VM = null,
    kill_requested: bool = false,
    /// the Sync the isolate's thread waits on, if any, for kill to wake
    waiting: std.atomic.Value(?*Sync) = .init(null),
    /// the search paths, the function and its arguments (consumed by the thread)
    start: Message,
    result: ?Message = null,
    /// the error value join raises
    failure: ?Message = null,
    /// the error as printed when nobody joins
    failure_text: ?[]u8 = null,
    // what the isolate's VM takes over from the one that spawned it
    io: std.Io,
    env: ?*std.process.Environ.Map,
    args: []const []const u8,
    embedded: []const vm_mod.EmbeddedFile,
    trace: bool,
    profile_path: ?[]u8 = null,

    const State = enum { running, done, failed, killed };

    fn retain(iso: *Isolate) void {
        _ = iso.refs.fetchAdd(1, .monotonic);
    }

    fn release(iso: *Isolate) void {
        if (iso.refs.fetchSub(1, .acq_rel) != 1) return;
        iso.start.deinit();
        if (iso.result) |*m| m.deinit();
        if (iso.failure) |*m| m.deinit();
        if (iso.failure_text) |t| shared.free(t);
        if (iso.profile_path) |p| shared.free(p);
        shared.destroy(iso);
    }

    /// Stops the isolate at its next safe point (or blocking wait).
    fn kill(iso: *Isolate, io: std.Io) void {
        iso.sync.lock(io);
        defer iso.sync.unlock(io);
        if (iso.state != .running) return;
        iso.kill_requested = true;
        const target = iso.vm orelse return;
        gc.interrupt(target);
        if (iso.waiting.load(.seq_cst)) |w| {
            w.lock(io);
            w.broadcast(io);
            w.unlock(io);
        }
    }

    /// Blocks until the isolate's thread is done; false when vm is killed
    /// meanwhile.
    fn waitDone(iso: *Isolate, th: *Thread) bool {
        const vm = th.vm;
        const rel = block(vm, th);
        defer unblock(vm, rel);
        iso.sync.lock(vm.io);
        defer iso.sync.unlock(vm.io);
        while (iso.state == .running) {
            if (!wait(vm, &iso.sync)) return false;
        }
        return true;
    }

    /// Its error was raised by a join: no longer printed at exit.
    fn taken(iso: *Isolate, io: std.Io) void {
        failed_lock.lockUncancelable(io);
        defer failed_lock.unlock(io);
        for (failed.items, 0..) |f, i| {
            if (f != iso) continue;
            _ = failed.swapRemove(i);
            iso.release();
            return;
        }
    }
};

fn threadMain(iso: *Isolate) void {
    const io = iso.io;
    const vm = VM.create(shared, io, iso.env);
    vm.args = iso.args;
    vm.embedded = iso.embedded;
    vm.isolate = iso;
    vm.trace = iso.trace;
    if (iso.profile_path) |p| vm.profiler = vm_mod.Profiler.create(vm.backing, io, p);
    stdlib.open(vm);
    iso.sync.lock(io);
    iso.vm = vm;
    if (iso.kill_requested) gc.interrupt(vm);
    iso.sync.unlock(io);

    var state: Isolate.State = .done;
    const outcome = run(vm, iso);
    // what it held (channels passed to spawn) is the VM's now
    iso.start.deinit();
    if (outcome) |res| {
        iso.result = res;
    } else |_| {
        if (vm.interrupt.load(.seq_cst)) {
            state = .killed;
        } else {
            recordFailure(vm, iso);
            state = .failed;
        }
    }
    vm.flush();
    iso.sync.lock(io);
    iso.vm = null;
    iso.sync.unlock(io);
    vm.destroy();

    if (state == .failed) {
        iso.retain();
        failed_lock.lockUncancelable(io);
        failed.append(shared, iso) catch oom();
        failed_lock.unlock(io);
    }
    iso.sync.lock(io);
    iso.state = state;
    iso.sync.broadcast(io);
    iso.sync.unlock(io);
    _ = running.fetchSub(1, .seq_cst);
    iso.release();
}

/// Boots the VM, calls the function and serializes its result. The
/// arguments are on the stack before anything can collect.
fn run(vm: *VM, iso: *Isolate) Error!Message {
    try stdlib.boot(vm);
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(vm.gpa);
    try decode(vm, &iso.start, &vals);
    vm.packages.set(vm.gpa, vm.str("search_paths"), vals.items[0]);
    vm.packages.set(vm.gpa, vm.str("native_search_paths"), vals.items[1]);
    const res = try vm.call(vals.items[2], vals.items[3..]);
    return encode(vm, &.{res}) catch {
        var e = vm.takeError();
        defer e.deinit(vm.gpa);
        return vm.raise("the isolate's result {s}", .{e.message});
    };
}

/// The pending error as the value join raises and as text for stderr.
fn recordFailure(vm: *VM, iso: *Isolate) void {
    var e = vm.takeError();
    var aw: std.Io.Writer.Allocating = .init(shared);
    aw.writer.print("isolate {d} failed: ", .{iso.id}) catch oom();
    e.write(&aw.writer) catch oom();
    iso.failure_text = aw.toOwnedSlice() catch oom();
    // a raised table that cannot cross is replaced by its message and stack
    const fallback = vm.newTable(0, 2);
    fallback.set(vm.gpa, vm.str("message"), vm.str(e.message));
    if (e.trace) |t| fallback.set(vm.gpa, vm.str("stack"), vm.str(t));
    vm.setErrorFull(e);
    const ev = vm.errorToValue();
    iso.failure = encode(vm, &.{ev}) catch blk: {
        var dropped = vm.takeError();
        dropped.deinit(vm.gpa);
        break :blk encode(vm, &.{.{ .table = fallback }}) catch unreachable;
    };
}

/// Prints the errors of isolates nobody joined. Then, if isolates still
/// run, the process ends here: they stop with it (the main program is
/// done; join is how to wait for them).
pub fn finish(vm: *VM, code: u8) void {
    printUnjoined(vm.io);
    if (running.load(.seq_cst) > 0) {
        vm.flush();
        std.process.exit(code);
    }
}

pub fn printUnjoined(io: std.Io) void {
    failed_lock.lockUncancelable(io);
    defer failed_lock.unlock(io);
    if (failed.items.len == 0) return;
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    for (failed.items) |iso| {
        if (iso.failure_text) |t| w.interface.writeAll(t) catch {};
        iso.release();
    }
    w.interface.flush() catch {};
    failed.clearRetainingCapacity();
}

// ------------------------------------------------------------ driven from C

/// A VM that an OS thread the caller owns drives (slang_isolate_new): set
/// up like a spawned isolate's, from parent, with v copied onto its stack.
/// Nothing runs it but its driver, one OS thread at a time; vm.destroy
/// (slang_close) ends it. Raises on parent when v cannot cross or the new
/// VM cannot boot.
pub fn newDriven(parent: *VM, v: Value) Error!*VM {
    if (!supported) return parent.raise("isolates are not available here (no threads)", .{});
    var start = try encode(parent, &.{
        parent.packages.getName("search_paths"),
        parent.packages.getName("native_search_paths"),
        v,
    });
    defer start.deinit();
    const vm = VM.create(shared, parent.io, parent.env);
    vm.args = parent.args;
    vm.embedded = parent.embedded;
    vm.driven = true;
    stdlib.open(vm);
    setupDriven(vm, &start) catch {
        var e = vm.takeError();
        defer e.deinit(vm.gpa);
        vm.destroy();
        return parent.raise("cannot start an isolate: {s}", .{e.message});
    };
    return vm;
}

fn setupDriven(vm: *VM, start: *const Message) Error!void {
    try stdlib.boot(vm);
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(vm.gpa);
    try decode(vm, start, &vals);
    vm.packages.set(vm.gpa, vm.str("search_paths"), vals.items[0]);
    vm.packages.set(vm.gpa, vm.str("native_search_paths"), vals.items[1]);
    try vm.main.ensure(vm.main.top + 1);
    vm.main.push(vals.items[2]);
}

/// slang_send and slang_trysend: v through the channel ch.
pub fn sendTo(th: *Thread, ch: Value, v: Value, blocking: bool) Error!bool {
    var args = [_]Value{ ch, v };
    return sendValue(th, &args, blocking);
}

/// slang_receive and slang_tryreceive: the next value of ch, or null.
pub fn receiveFrom(th: *Thread, ch: Value, blocking: bool) Error!Value {
    var args = [_]Value{ch};
    return receiveValue(th, try argChannel(th, &args, 0), blocking);
}

// ------------------------------------------------------------ handles

fn channelFinalize(data: ?*anyopaque) callconv(.c) void {
    const box: **Channel = @ptrCast(@alignCast(data.?));
    box.*.release();
}

fn isolateFinalize(data: ?*anyopaque) callconv(.c) void {
    const box: **Isolate = @ptrCast(@alignCast(data.?));
    box.*.release();
}

fn channelToString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("channel: 0x{x}", .{@intFromPtr(u.as(*Channel).*)});
}

fn isolateToString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("isolate {d}", .{u.as(*Isolate).*.id});
}

/// A handle in vm for r, holding a reference of its own.
fn newHandle(vm: *VM, r: Ref) Value {
    r.retain();
    const u = switch (r) {
        .channel => |c| blk: {
            const u = vm.newUserdataOf(*Channel, c, channel_tname, vm.lib.channel_meta);
            u.finalizer = channelFinalize;
            u.to_string = channelToString;
            break :blk u;
        },
        .isolate => |iso| blk: {
            const u = vm.newUserdataOf(*Isolate, iso, isolate_tname, vm.lib.isolate_meta);
            u.finalizer = isolateFinalize;
            u.to_string = isolateToString;
            break :blk u;
        },
        .shared => unreachable, // buffers are decoded by Decoder
    };
    return .{ .userdata = u };
}

fn argChannel(th: *Thread, args: []Value, i: usize) Error!*Channel {
    return (try api.argUserdata(th, args, i, "channel", *Channel, channel_tname)).*;
}

fn argIsolate(th: *Thread, args: []Value, i: usize) Error!*Isolate {
    return (try api.argUserdata(th, args, i, "isolate", *Isolate, isolate_tname)).*;
}

// ------------------------------------------------------------ the module

pub fn module(vm: *VM) *Table {
    const cm = vm.newTable(0, 3);
    cm.set(vm.gpa, vm.str("__index"), .{ .table = stdlib.makeModule(vm, &.{
        .{ .name = "send", .f = chSend },
        .{ .name = "receive", .f = chReceive },
        .{ .name = "try_send", .f = chTrySend },
        .{ .name = "try_receive", .f = chTryReceive },
        .{ .name = "close", .f = chClose },
        .{ .name = "is_closed", .f = chIsClosed },
        .{ .name = "len", .f = chLen },
        .{ .name = "capacity", .f = chCapacity },
        .{ .name = "watch", .f = chWatch },
        .{ .name = "unwatch", .f = chUnwatch },
    }) });
    cm.set(vm.gpa, vm.str("__eq"), vm.nativeValue("channel.__eq", handleEq));
    cm.set(vm.gpa, vm.str("__type"), vm.str(channel_tname));
    vm.lib.channel_meta = cm;
    vm.registry.set(vm.gpa, vm.str("isolate_channel_meta"), .{ .table = cm });

    const im = vm.newTable(0, 3);
    im.set(vm.gpa, vm.str("__index"), .{ .table = stdlib.makeModule(vm, &.{
        .{ .name = "join", .f = isoJoin },
        .{ .name = "kill", .f = isoKill },
        .{ .name = "is_running", .f = isoIsRunning },
        .{ .name = "id", .f = isoHandleId },
    }) });
    im.set(vm.gpa, vm.str("__eq"), vm.nativeValue("isolate.__eq", handleEq));
    im.set(vm.gpa, vm.str("__type"), vm.str(isolate_tname));
    vm.lib.isolate_meta = im;
    vm.registry.set(vm.gpa, vm.str("isolate_isolate_meta"), .{ .table = im });

    return stdlib.makeModule(vm, &.{
        .{ .name = "available", .f = isoAvailable },
        .{ .name = "spawn", .f = isoSpawn },
        .{ .name = "channel", .f = isoChannel },
        .{ .name = "each", .f = isoEach },
        .{ .name = "id", .f = isoId },
        .{ .name = "cpu_count", .f = isoCpuCount },
    });
}

/// Two handles are equal when they name the same channel or isolate.
fn handleEq(th: *Thread, args: []Value) Error!Value {
    _ = th;
    const a = api.arg(args, 0).asUserdata() orelse return .{ .bool = false };
    const b = api.arg(args, 1).asUserdata() orelse return .{ .bool = false };
    if (!std.mem.eql(u8, a.tname, b.tname)) return .{ .bool = false };
    return .{ .bool = a.as(*anyopaque).* == b.as(*anyopaque).* };
}

/// available() -> bool: whether spawn works here (not in a browser).
fn isoAvailable(th: *Thread, args: []Value) Error!Value {
    _ = th;
    _ = args;
    return .{ .bool = supported };
}

/// id() -> int: the running isolate's id; the main program is 0.
fn isoId(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const iso = currentIsolate(th.vm) orelse return .{ .int = 0 };
    return .{ .int = iso.id };
}

/// cpu_count() -> int: how many CPUs run threads (1 without threads).
fn isoCpuCount(th: *Thread, args: []Value) Error!Value {
    _ = th;
    _ = args;
    if (!supported) return .{ .int = 1 };
    const n = std.Thread.getCpuCount() catch 1;
    return .{ .int = @intCast(n) };
}

/// spawn(f, ...args) -> isolate: runs f(args) in a new isolate.
fn isoSpawn(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    if (!supported) return vm.raise("isolates are not available here (no threads)", .{});
    _ = try api.argFunction(th, args, 0, "f");
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(vm.gpa);
    vals.append(vm.gpa, vm.packages.getName("search_paths")) catch oom();
    vals.append(vm.gpa, vm.packages.getName("native_search_paths")) catch oom();
    vals.appendSlice(vm.gpa, args) catch oom();
    const start = try encode(vm, vals.items);

    const id = next_id.fetchAdd(1, .monotonic);
    var profile_path: ?[]u8 = null;
    if (vm.getenv("SLANG_PROFILE")) |p| profile_path = std.fmt.allocPrint(shared, "{s}.{d}", .{ p, id }) catch oom();
    const iso = shared.create(Isolate) catch oom();
    iso.* = .{
        .id = id,
        .start = start,
        .io = vm.io,
        .env = vm.env,
        .args = vm.args,
        .embedded = vm.embedded,
        .trace = vm.trace,
        .profile_path = profile_path,
    };
    // one reference for the thread, one for the handle (newHandle)
    _ = running.fetchAdd(1, .seq_cst);
    const thread = std.Thread.spawn(.{}, threadMain, .{iso}) catch |e| {
        _ = running.fetchSub(1, .seq_cst);
        iso.release();
        return vm.raise("cannot start an isolate: {t}", .{e});
    };
    thread.detach();
    return newHandle(vm, .{ .isolate = iso });
}

/// isolate:join() -> any: waits for the isolate to end and returns its
/// function's result, or raises its error. A killed isolate gives null.
fn isoJoin(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const iso = try argIsolate(th, args, 0);
    if (currentIsolate(vm) == iso) return vm.raise("an isolate cannot join itself", .{});
    if (!iso.waitDone(th)) return killed(vm);
    switch (iso.state) {
        .running => unreachable,
        .killed => return .null,
        .done => return decodeOne(vm, &iso.result.?),
        .failed => {
            iso.taken(vm.io);
            const ev = try decodeOne(vm, &iso.failure.?);
            vm.setErrorFromValue(ev);
            return error.Slang;
        },
    }
}

/// isolate:kill(): stops the isolate at its next safe point (a call, a
/// loop, a blocking receive) and waits for it to end. Code running in C
/// (a sleep, a long C call) is stopped when it returns to slang.
fn isoKill(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const iso = try argIsolate(th, args, 0);
    if (currentIsolate(vm) == iso) return vm.raise("an isolate cannot kill itself", .{});
    iso.kill(vm.io);
    if (!iso.waitDone(th)) return killed(vm);
    if (iso.state == .failed) iso.taken(vm.io);
    return .null;
}

fn isoIsRunning(th: *Thread, args: []Value) Error!Value {
    const iso = try argIsolate(th, args, 0);
    iso.sync.lock(th.vm.io);
    defer iso.sync.unlock(th.vm.io);
    return .{ .bool = iso.state == .running };
}

fn isoHandleId(th: *Thread, args: []Value) Error!Value {
    const iso = try argIsolate(th, args, 0);
    return .{ .int = iso.id };
}

/// channel({capacity: n}?) -> channel: unbounded by default (send never
/// blocks); with a capacity, send blocks while it holds that many.
fn isoChannel(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    var capacity: usize = 0;
    if (api.arg(args, 0).asTable()) |opts| {
        const c = opts.getName("capacity");
        if (c != .null) {
            if (c != .int or c.int < 1) return vm.raise("channel: capacity must be an int of at least 1", .{});
            capacity = @intCast(c.int);
        }
    } else if (api.arg(args, 0) != .null) {
        return api.argError(th, "options", 0, "SlangTable", args[0]);
    }
    const c = shared.create(Channel) catch oom();
    c.* = .{ .capacity = capacity };
    const h = newHandle(vm, .{ .channel = c });
    c.release();
    return h;
}

fn sendValue(th: *Thread, args: []Value, blocking: bool) Error!bool {
    const vm = th.vm;
    const c = try argChannel(th, args, 0);
    const v = api.arg(args, 1);
    if (v == .null) return vm.raise("cannot send null through a channel (receive gives null for a closed channel)", .{});
    var msg = try encode(vm, &.{v});
    switch (c.put(th, msg, blocking)) {
        .ok => return true,
        .full => {
            msg.deinit();
            return false;
        },
        .closed => {
            msg.deinit();
            return vm.raise("send on a closed channel", .{});
        },
        .killed => {
            msg.deinit();
            return killed(vm);
        },
    }
}

/// channel:send(value): copies value into the channel; blocks while a
/// channel with a capacity is full. Raises on a closed channel.
fn chSend(th: *Thread, args: []Value) Error!Value {
    _ = try sendValue(th, args, true);
    return .null;
}

/// channel:try_send(value) -> bool: like send, but false instead of
/// blocking when the channel is full.
fn chTrySend(th: *Thread, args: []Value) Error!Value {
    return .{ .bool = try sendValue(th, args, false) };
}

fn receiveValue(th: *Thread, c: *Channel, blocking: bool) Error!Value {
    switch (c.take(th, blocking)) {
        .msg => |m| {
            var msg = m;
            defer msg.deinit();
            return decodeOne(th.vm, &msg);
        },
        .empty, .closed => return .null,
        .killed => return killed(th.vm),
    }
}

/// channel:receive() -> any: the next value, waiting for one; null once
/// the channel is closed and empty.
fn chReceive(th: *Thread, args: []Value) Error!Value {
    return receiveValue(th, try argChannel(th, args, 0), true);
}

/// channel:try_receive() -> any: the next value, or null when there is
/// none (yet: is_closed tells whether more can come).
fn chTryReceive(th: *Thread, args: []Value) Error!Value {
    return receiveValue(th, try argChannel(th, args, 0), false);
}

/// channel:close(): no more sends; receivers get what is queued, then null.
fn chClose(th: *Thread, args: []Value) Error!Value {
    const c = try argChannel(th, args, 0);
    c.sync.lock(th.vm.io);
    defer c.sync.unlock(th.vm.io);
    c.closed = true;
    c.changed(th.vm.io);
    return .null;
}

fn chIsClosed(th: *Thread, args: []Value) Error!Value {
    const c = try argChannel(th, args, 0);
    c.sync.lock(th.vm.io);
    defer c.sync.unlock(th.vm.io);
    return .{ .bool = c.closed };
}

/// channel:len() -> int: how many values are queued.
fn chLen(th: *Thread, args: []Value) Error!Value {
    const c = try argChannel(th, args, 0);
    c.sync.lock(th.vm.io);
    defer c.sync.unlock(th.vm.io);
    return .{ .int = @intCast(c.count()) };
}

/// channel:capacity() -> int: the capacity, or null for an unbounded one.
fn chCapacity(th: *Thread, args: []Value) Error!Value {
    const c = try argChannel(th, args, 0);
    if (c.capacity == 0) return .null;
    return .{ .int = @intCast(c.capacity) };
}

/// The uv extension's C API (extensions/native/slang_uv.h), as far as
/// watch needs it.
const UvApi = extern struct {
    version: c_int,
    queue: ?*const anyopaque,
    run: ?*const anyopaque,
    backend_fd: ?*const anyopaque,
    backend_timeout: ?*const anyopaque,
    hold: ?*const anyopaque,
    async_handle: *const fn (th: *Thread, idx: c_int) callconv(.c) ?*anyopaque,
    async_send: *const fn (h: ?*anyopaque) callconv(.c) c_int,
};

/// The uv async handle at args[1] as a waker (uv.async(cb); slang/async's
/// receive uses it).
fn asyncWaker(th: *Thread, args: []Value) Error!Waker {
    const vm = th.vm;
    const req = try th.call(vm.getGlobal("require"), &.{vm.str("uv")});
    const box_v = if (req.asTable()) |t| t.getName("c_api") else Value.null;
    const box = box_v.asUserdata() orelse return vm.raise("watch: the uv extension has no C API", .{});
    const uv: *const UvApi = box.as(*const UvApi).*;
    if (uv.version < 4) return vm.raise("watch: the uv extension is too old (C API version {d}, want 4)", .{uv.version});
    // the handle as a stack index for the C API (the require may have
    // moved the stack: arguments are read again)
    _ = args;
    try th.ensure(th.top + 1);
    th.push(th.arg(1));
    defer th.top -= 1;
    const ptr = uv.async_handle(th, -1) orelse return vm.raise("watch: a uv async handle expected (uv.async(callback))", .{});
    return .{ .send = uv.async_send, .ctx = ptr };
}

/// channel:watch(handle): handle (uv.async(cb)) is sent whenever the
/// channel changes, so that cb, on the loop, can try_receive; it is sent
/// at once when values are queued or the channel is closed. unwatch before
/// closing the handle.
fn chWatch(th: *Thread, args: []Value) Error!Value {
    const c = try argChannel(th, args, 0);
    const w = try asyncWaker(th, args);
    c.sync.lock(th.vm.io);
    defer c.sync.unlock(th.vm.io);
    c.wakers.append(shared, w) catch oom();
    if (c.count() > 0 or c.closed) _ = w.send(w.ctx);
    return .null;
}

fn chUnwatch(th: *Thread, args: []Value) Error!Value {
    const c = try argChannel(th, args, 0);
    const w = try asyncWaker(th, args);
    c.sync.lock(th.vm.io);
    defer c.sync.unlock(th.vm.io);
    for (c.wakers.items, 0..) |x, i| {
        if (x.ctx != w.ctx) continue;
        _ = c.wakers.orderedRemove(i);
        break;
    }
    return .null;
}

/// each(channel) -> iterator: for(let local v in each(ch)) receives until
/// the channel is closed (or a value is false).
fn isoEach(th: *Thread, args: []Value) Error!Value {
    _ = try argChannel(th, args, 0);
    return .{ .function = th.vm.newNative("each", eachNext, &.{args[0]}) };
}

fn eachNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const v = th.currentClosure().nvals[0];
    return receiveValue(th, v.userdata.as(*Channel).*, true);
}
