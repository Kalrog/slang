//! Memory management: a stop-the-world, non-moving mark and sweep collector.
//!
//! Every heap object is linked into vm.objects. A collection runs only at
//! interpreter safe points (calls, backward jumps, table and closure
//! creation), never inside an allocation, so native code may hold object
//! pointers freely between calls back into the VM. At a safe point every
//! live value is reachable from the roots: the globals, the package table,
//! the registry and the main thread (and from there every thread stack,
//! frame, open upvalue and suspended coroutine that is still referenced).
//!
//! The threshold is based on the bytes the VM has allocated through its
//! counting allocator (objects, table storage, stacks): after a collection
//! the next one happens when the live size has doubled (vm.gc_growth, at
//! least vm.gc_minimum bytes), or never while vm.gc_automatic is off;
//! slang/vm's gc sets them and collect() runs one at once.
//!
//! Finalizers (slang/vm's on_collect) and weak tables: a registered object
//! keeps its finalizer alive only through itself (as an ephemeron does), so
//! a finalizer that refers to its object does not keep it alive. After
//! marking, weak entries whose key or value is unreachable are cleared;
//! then every unreachable registered object is kept for one more cycle with
//! what it refers to, and its finalizer queued. The queued finalizers run
//! once the collection is over (runFinalizers), on a thread of their own,
//! so the code the collection interrupted is never touched.

const std = @import("std");
const build_options = @import("build_options");
const root = @import("../vm.zig");
const VM = root.VM;
const Value = root.Value;
const Thread = root.Thread;
const Object = root.Object;
const String = root.String;
const Table = root.Table;
const Closure = root.Closure;
const Upvalue = root.Upvalue;
const Userdata = root.Userdata;
const Proto = root.Proto;
const oom = root.oom;

pub const initial_threshold: usize = 8 << 20;

/// What slang/vm's on_collect registered: f(obj) runs once obj is
/// unreachable.
pub const Finalizer = struct { obj: Value, f: Value };
/// In stress mode a collection runs as soon as this much has been
/// allocated since the previous one.
pub const stress_step: usize = 64 << 10;

/// Wraps the backing allocator and keeps vm.bytes_allocated exact.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    counter: *usize,
    /// freed small blocks by size class (see class): handed out again
    /// before the backing allocator is asked, so the tables, closures and
    /// short strings a program makes and drops cost no malloc or free
    pools: [classes]?*FreeBlock = @splat(null),
    /// the bytes the pools hold
    pooled: usize = 0,

    /// Blocks of up to max_small bytes come in classes of granule bytes.
    pub const granule = 16;
    pub const max_small = 256;
    const classes = max_small / granule;

    const FreeBlock = struct { next: ?*FreeBlock };

    /// The class of a block of len bytes and this alignment, or null for
    /// one the pools do not take (large, or aligned beyond a granule).
    /// The GC-stress build does without pools: a block freed too early
    /// then reaches the checked allocator, which reports its later use.
    const pooling = !build_options.gc_stress;

    inline fn class(len: usize, alignment: std.mem.Alignment) ?usize {
        if (!pooling) return null;
        if (len == 0 or len > max_small or alignment.toByteUnits() > granule) return null;
        return (len - 1) / granule;
    }

    inline fn classSize(c: usize) usize {
        return (c + 1) * granule;
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = if (class(len, alignment)) |c| blk: {
            if (self.pools[c]) |b| {
                self.pools[c] = b.next;
                self.pooled -= classSize(c);
                break :blk @as([*]u8, @ptrCast(b));
            }
            // a whole class, so that the block can serve any size of it
            break :blk self.backing.vtable.alloc(self.backing.ptr, classSize(c), .fromByteUnits(granule), ret_addr);
        } else self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
        if (p != null) self.counter.* += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const old = class(memory.len, alignment);
        const new = class(new_len, alignment);
        if (old != null or new != null) {
            // a pooled block can only change size within its class
            if (old == null or new == null or old.? != new.?) return false;
        } else if (!self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr)) {
            return false;
        }
        self.counter.* = self.counter.* + new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (class(memory.len, alignment) != null or class(new_len, alignment) != null) {
            if (!resize(ctx, memory, alignment, new_len, ret_addr)) return null;
            return memory.ptr;
        }
        const p = self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
        if (p != null) self.counter.* = self.counter.* + new_len - memory.len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.counter.* -= memory.len;
        if (class(memory.len, alignment)) |c| {
            const b: *FreeBlock = @ptrCast(@alignCast(memory.ptr));
            b.next = self.pools[c];
            self.pools[c] = b;
            self.pooled += classSize(c);
            return;
        }
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
    }

    /// Gives pooled blocks back to the backing allocator until the pools
    /// hold at most keep bytes (after a collection: what a burst of garbage
    /// left is not kept for good).
    pub fn trim(self: *CountingAllocator, keep: usize) void {
        var c: usize = classes;
        while (self.pooled > keep and c > 0) {
            c -= 1;
            while (self.pooled > keep) {
                const b = self.pools[c] orelse break;
                self.pools[c] = b.next;
                self.pooled -= classSize(c);
                const mem: [*]u8 = @ptrCast(b);
                self.backing.vtable.free(self.backing.ptr, mem[0..classSize(c)], .fromByteUnits(granule), @returnAddress());
            }
        }
    }

    /// Everything pooled goes back (the VM is destroyed).
    pub fn release(self: *CountingAllocator) void {
        self.trim(0);
    }
};

/// Called by the interpreter at safe points. An isolate being killed sets
/// next_gc to 0, so the interrupt check costs nothing on the fast path.
pub inline fn safePoint(vm: *VM, th: *Thread) root.Error!void {
    if (vm.bytes_allocated >= vm.next_gc) try slowPoint(vm, th);
}

fn slowPoint(vm: *VM, th: *Thread) root.Error!void {
    _ = th;
    if (vm.interrupt.load(.seq_cst)) return vm.raise("isolate killed", .{});
    collect(vm);
    runFinalizers(vm);
}

/// Stops vm at its next safe point; called from another OS thread.
pub fn interrupt(vm: *VM) void {
    vm.interrupt.store(true, .seq_cst);
    @atomicStore(usize, &vm.next_gc, 0, .seq_cst);
    // what waits outside the interpreter (an event loop) is woken
    vm.hooks_lock.lockUncancelable(vm.io);
    defer vm.hooks_lock.unlock(vm.io);
    for (vm.interrupt_hooks.items) |h| h.f(h.data);
}

/// Whether a weak table can lose an entry to this value: strings, numbers
/// and the like are values, never collected out of one.
fn collectable(v: Value) bool {
    const o = v.heapObject() orelse return false;
    return o.kind != .string;
}

fn isMarked(v: Value) bool {
    const o = v.heapObject() orelse return true;
    return o.marked;
}

const Marker = struct {
    vm: *VM,
    gray: std.ArrayList(*Object),
    /// the weak-keyed tables reached, for converge
    ephemerons: std.ArrayList(*Table) = .empty,

    fn markValue(m: *Marker, v: Value) void {
        if (v.heapObject()) |o| m.markObject(o);
    }

    fn markObject(m: *Marker, o: *Object) void {
        if (o.marked) return;
        o.marked = true;
        if (o.kind == .string) return; // leaf
        m.gray.append(m.vm.gpa, o) catch oom();
    }

    fn markTable(m: *Marker, t: ?*Table) void {
        if (t) |p| m.markObject(&p.obj);
    }

    fn drain(m: *Marker) void {
        while (m.gray.pop()) |o| m.blacken(o);
    }

    fn blacken(m: *Marker, o: *Object) void {
        switch (o.kind) {
            .string => {},
            .table => {
                const t: *Table = @alignCast(@fieldParentPtr("obj", o));
                m.markTable(t.meta);
                switch (t.weak) {
                    .none => {
                        for (t.arr.items) |v| m.markValue(v);
                        for (t.ents.items) |e| {
                            m.markValue(e.key);
                            m.markValue(e.val);
                        }
                    },
                    // the values only when they cannot be collected
                    .values => {
                        for (t.arr.items) |v| {
                            if (!collectable(v)) m.markValue(v);
                        }
                        for (t.ents.items) |e| {
                            m.markValue(e.key);
                            if (!collectable(e.val)) m.markValue(e.val);
                        }
                    },
                    // a value once its key is alive (see converge)
                    .keys => {
                        for (t.arr.items) |v| m.markValue(v);
                        for (t.ents.items) |e| {
                            if (!collectable(e.key)) {
                                m.markValue(e.key);
                                m.markValue(e.val);
                            }
                        }
                        m.ephemerons.append(m.vm.gpa, t) catch oom();
                    },
                }
            },
            .closure => {
                const c: *Closure = @alignCast(@fieldParentPtr("obj", o));
                if (c.proto) |p| m.markObject(&p.obj);
                for (c.upvals) |u| m.markObject(&u.obj);
                if (c.name) |n| m.markObject(&n.obj);
                for (c.nvals) |v| m.markValue(v);
            },
            .upvalue => {
                const u: *Upvalue = @alignCast(@fieldParentPtr("obj", o));
                if (u.th) |th| m.markObject(&th.obj) else m.markValue(u.v);
            },
            .userdata => {
                const u: *Userdata = @alignCast(@fieldParentPtr("obj", o));
                m.markTable(u.meta);
                m.markValue(u.owner);
                m.markValue(u.keep);
            },
            .proto => {
                const p: *Proto = @alignCast(@fieldParentPtr("obj", o));
                for (p.consts) |v| m.markValue(v);
                for (p.upvals) |u| m.markObject(&u.name.obj);
                for (p.locs) |l| m.markObject(&l.origin.obj);
                for (p.locals) |l| m.markObject(&l.name.obj);
                if (p.name) |n| m.markObject(&n.obj);
                for (p.children) |c| m.markObject(&c.obj);
            },
            .thread => {
                const th: *Thread = @alignCast(@fieldParentPtr("obj", o));
                for (th.stack[0..th.top]) |v| m.markValue(v);
                for (th.frames.items) |fr| m.markObject(&fr.cl.obj);
                for (th.open_upvals.items) |u| m.markObject(&u.obj);
                if (th.entry) |e| m.markObject(&e.obj);
                m.markValue(th.yielded);
            },
        }
    }

    /// Marks until nothing new is reached through what only counts when
    /// its holder is alive: the value of a weak key that is, and the
    /// finalizer of a registered object that is.
    fn converge(m: *Marker) void {
        while (true) {
            for (m.ephemerons.items) |t| {
                for (t.ents.items) |e| {
                    if (collectable(e.key) and isMarked(e.key) and !isMarked(e.val)) m.markValue(e.val);
                }
            }
            var it = m.vm.finalizers.valueIterator();
            while (it.next()) |f| {
                if (isMarked(f.obj) and !isMarked(f.f)) m.markValue(f.f);
            }
            if (m.gray.items.len == 0) return;
            m.drain();
        }
    }
};

/// Removes the entries of the weak tables reached whose weak key or value
/// was not.
fn clearWeak(vm: *VM) void {
    var dead: std.ArrayList(Value) = .empty;
    defer dead.deinit(vm.gpa);
    for (vm.weak_tables.items) |t| {
        if (!t.obj.marked) continue;
        dead.clearRetainingCapacity();
        for (t.arr.items, 0..) |v, i| {
            if (t.weak == .values and collectable(v) and !isMarked(v)) dead.append(vm.gpa, .{ .int = @intCast(i) }) catch oom();
        }
        for (t.ents.items) |e| {
            if (e.key == .null) continue; // a removed entry
            const gone = switch (t.weak) {
                .keys => collectable(e.key) and !isMarked(e.key),
                .values => collectable(e.val) and !isMarked(e.val),
                .none => false,
            };
            if (gone) dead.append(vm.gpa, e.key) catch oom();
        }
        for (dead.items) |k| _ = t.remove(vm.gpa, k);
    }
}

pub fn collect(vm: *VM) void {
    if (vm.gc_running) return;
    vm.gc_running = true;
    defer vm.gc_running = false;

    var m: Marker = .{ .vm = vm, .gray = .empty };
    defer m.gray.deinit(vm.gpa);
    defer m.ephemerons.deinit(vm.gpa);
    m.markTable(vm.globals);
    m.markTable(vm.packages);
    m.markTable(vm.registry);
    m.markObject(&vm.main.obj);
    // a pending error's raised value
    if (vm.err) |e| m.markValue(e.value);
    if (vm.ffi.pending) |e| m.markValue(e.value);
    var foreign = vm.ffi.foreign.valueIterator();
    while (foreign.next()) |t| m.markObject(&t.*.obj);
    for (vm.ffi.calls.items) |c| m.markObject(&c.th.obj);
    if (vm.finalizer_thread) |t| m.markObject(&t.obj);
    for (vm.pending_finalizers.items) |p| {
        m.markValue(p.obj);
        m.markValue(p.f);
    }
    m.drain();
    m.converge();
    clearWeak(vm);

    // the unreachable registered objects: kept for their finalizers
    var dying: std.ArrayList(*Object) = .empty;
    defer dying.deinit(vm.gpa);
    var it = vm.finalizers.iterator();
    while (it.next()) |e| {
        if (!e.key_ptr.*.marked) dying.append(vm.gpa, e.key_ptr.*) catch oom();
    }
    for (dying.items) |o| {
        const f = vm.finalizers.fetchRemove(o).?.value;
        vm.pending_finalizers.append(vm.gpa, f) catch oom();
        m.markValue(f.obj);
        m.markValue(f.f);
    }
    if (dying.items.len > 0) {
        m.drain();
        m.converge();
        // (weak tables reached only through what was kept)
        clearWeak(vm);
    }
    // the weak tables that go now
    var keep: usize = 0;
    for (vm.weak_tables.items) |t| {
        if (t.obj.marked) {
            vm.weak_tables.items[keep] = t;
            keep += 1;
        }
    }
    vm.weak_tables.shrinkRetainingCapacity(keep);

    sweep(vm);
    vm.compactStrings();
    // the pools keep what the next cycle's allocations will likely reuse:
    // up to half the live size (and at least the minimum's worth)
    vm.counting.trim(@max(vm.bytes_allocated / 2, vm.gc_minimum / 2));
    vm.collections += 1;
    schedule(vm);
}

/// Sets the threshold of the next automatic collection from the settings
/// and the live size: after a collection, and when the settings change.
pub fn schedule(vm: *VM) void {
    const next: usize = if (!vm.gc_automatic)
        std.math.maxInt(usize)
    else if (build_options.gc_stress)
        vm.bytes_allocated + stress_step
    else blk: {
        const grown = @as(f64, @floatFromInt(vm.bytes_allocated)) * vm.gc_growth;
        const limit: f64 = @floatFromInt(std.math.maxInt(usize));
        break :blk @max(vm.gc_minimum, if (grown >= limit) std.math.maxInt(usize) else @as(usize, @intFromFloat(grown)));
    };
    @atomicStore(usize, &vm.next_gc, next, .seq_cst);
    // a kill that arrived meanwhile keeps its zero
    if (vm.interrupt.load(.seq_cst)) @atomicStore(usize, &vm.next_gc, 0, .seq_cst);
}

fn sweep(vm: *VM) void {
    var link: *?*Object = &vm.objects;
    while (link.*) |o| {
        if (o.marked) {
            o.marked = false;
            link = &o.next;
        } else {
            link.* = o.next;
            freeObject(vm, o);
        }
    }
}

fn freeObject(vm: *VM, o: *Object) void {
    const gpa = vm.gpa;
    switch (o.kind) {
        .string => {
            const s: *String = @alignCast(@fieldParentPtr("obj", o));
            if (s.interned and vm.strings.remove(s)) vm.strings_removed += 1;
            const mem: [*]align(@alignOf(String)) u8 = @ptrCast(s);
            gpa.free(mem[0..String.allocSize(s.len)]);
        },
        .table => {
            const t: *Table = @alignCast(@fieldParentPtr("obj", o));
            t.deinit(gpa);
            if (t.isInline()) {
                const mem: [*]align(@alignOf(Table)) u8 = @ptrCast(t);
                gpa.free(mem[0..Table.allocSize(t.inline_arr, t.inline_ents)]);
            } else {
                gpa.destroy(t);
            }
        },
        .closure => {
            const c: *Closure = @alignCast(@fieldParentPtr("obj", o));
            gpa.free(c.upvals);
            gpa.free(c.nvals);
            gpa.destroy(c);
        },
        .upvalue => {
            const u: *Upvalue = @alignCast(@fieldParentPtr("obj", o));
            gpa.destroy(u);
        },
        .userdata => {
            const u: *Userdata = @alignCast(@fieldParentPtr("obj", o));
            if (u.finalizer) |f| f(u.data.ptr);
            gpa.free(@as([]align(16) u8, @alignCast(u.data)));
            gpa.destroy(u);
        },
        .proto => {
            const p: *Proto = @alignCast(@fieldParentPtr("obj", o));
            p.deinit(gpa);
            gpa.destroy(p);
        },
        .thread => {
            const t: *Thread = @alignCast(@fieldParentPtr("obj", o));
            t.deinit();
            gpa.destroy(t);
        },
    }
}

/// Runs the queued finalizers (after a collection, never during one), each
/// on the VM's finalizer thread with its object as the argument. A
/// finalizer that raises is reported on stderr and the others still run;
/// one that runs while finalizers are running only adds to the queue. A
/// kill stops them: the rest wait for the next collection.
pub fn runFinalizers(vm: *VM) void {
    if (vm.running_finalizers or vm.pending_finalizers.items.len == 0) return;
    vm.running_finalizers = true;
    defer vm.running_finalizers = false;
    const th = vm.finalizer_thread orelse blk: {
        const t = vm.newThread(null);
        vm.finalizer_thread = t;
        break :blk t;
    };
    while (vm.pending_finalizers.items.len > 0) {
        if (vm.interrupt.load(.seq_cst)) return;
        const p = vm.pending_finalizers.orderedRemove(0);
        _ = th.call(p.f, &.{p.obj}) catch |e| {
            if (e != error.Slang) continue;
            var err = vm.takeError();
            defer err.deinit(vm.gpa);
            var eb: [256]u8 = undefined;
            var ew = std.Io.File.stderr().writerStreaming(vm.io, &eb);
            const w = &ew.interface;
            w.print("error in a finalizer (vm.on_collect): {s}\n", .{err.message}) catch {};
            if (err.loc) |l| w.print("  at {s}:{d}:{d}\n", .{ l.origin, l.line, l.column }) catch {};
            w.flush() catch {};
        };
    }
}

/// At VM shutdown, before anything is freed: the finalizers of every object
/// still registered (and of those their finalizers register, a few rounds
/// deep).
pub fn finalizeAll(vm: *VM) void {
    var rounds: usize = 0;
    while (rounds < 4 and (vm.finalizers.count() > 0 or vm.pending_finalizers.items.len > 0)) : (rounds += 1) {
        var it = vm.finalizers.valueIterator();
        while (it.next()) |f| vm.pending_finalizers.append(vm.gpa, f.*) catch oom();
        vm.finalizers.clearRetainingCapacity();
        runFinalizers(vm);
    }
}

/// Frees every object (VM shutdown).
pub fn freeAll(vm: *VM) void {
    var o = vm.objects;
    while (o) |obj| {
        o = obj.next;
        freeObject(vm, obj);
    }
    vm.objects = null;
}
