//! Memory management: a non-moving mark and sweep collector that works in
//! steps (incremental), so that a collection never stops the program for
//! the whole heap at once.
//!
//! Every heap object is linked into vm.objects. The collector runs only at
//! interpreter safe points (calls, backward jumps, table and closure
//! creation), never inside an allocation, so native code may hold object
//! pointers freely between calls back into the VM. At a safe point every
//! live value is reachable from the roots: the globals, the package table,
//! the registry and the main thread (and from there every thread stack,
//! frame, open upvalue and suspended coroutine that is still referenced).
//!
//! A cycle: when the bytes the VM has allocated through its counting
//! allocator pass the threshold (the live size times vm.gc_growth, at least
//! vm.gc_minimum, never while vm.gc_automatic is off), marking starts at the
//! roots. Then a step runs every step_bytes allocated and marks in
//! proportion to what was allocated, until nothing is left to mark; the
//! atomic step marks the roots and every reached thread again (stacks
//! change without a barrier), settles weak tables and finalizers and
//! swaps the whites; sweeping frees the dead in steps too. slang/vm's
//! collect() finishes a running cycle and runs a whole one at once.
//!
//! Colors: an object is black once reached (gray while it waits on the gray
//! list to be scanned); unreached objects are one of two whites. New objects
//! get the current white; the atomic step swaps the current white, so the
//! sweep frees exactly what is still the old white and turns everything
//! else, objects made during the sweep included, into the new one.
//!
//! The write barrier: while marking, storing a value into a black object
//! marks the value (Dijkstra's insertion barrier), so a reached object never
//! refers to an unreached one. Outside marking every object is white and the
//! barrier is one compare. The stores that need it: every Table mutation
//! (table.zig finds the VM through the counting allocator it is given),
//! metatables, a buffer's keep, closed upvalues. A store into an object made
//! since the last safe point needs none (it is white), nor do thread stacks
//! (rescanned). The GC-stress build steps every few KB and checks after the
//! atomic step that no black object refers to a white one.
//!
//! Finalizers (slang/vm's on_collect) and weak tables: a registered object
//! keeps its finalizer alive only through itself (as an ephemeron does), so
//! a finalizer that refers to its object does not keep it alive. In the
//! atomic step, weak entries whose key or value is unreachable are cleared;
//! then every unreachable registered object is kept for one more cycle with
//! what it refers to, and its finalizer queued. The queued finalizers run
//! after that step (runFinalizers), on a thread of their own, so the code
//! the collection interrupted is never touched. A value stored into a
//! reached weak table while marking stays for that cycle (the barrier marks
//! it); the next cycle clears it.

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
const Allocator = std.mem.Allocator;

pub const initial_threshold: usize = 8 << 20;

/// When a new VM's first cycle starts: in the GC-stress build as soon as
/// for any later one (before, a program under 8 MB was never collected
/// there at all).
pub const first_threshold: usize = if (build_options.gc_stress) stress_step else initial_threshold;

/// What slang/vm's on_collect registered: f(obj) runs once obj is
/// unreachable.
pub const Finalizer = struct { obj: Value, f: Value };
/// In stress mode a cycle starts as soon as this much has been allocated
/// since the previous one ended.
pub const stress_step: usize = 64 << 10;

/// A cycle's steps run every step_bytes allocated (stress: every few KB);
/// each marks step_bytes * step_mul / 16 slots (values scanned) or sweeps
/// step_bytes * step_mul / 256 objects (freeing costs more than marking),
/// so the collector stays ahead of the program and a step stays well
/// under a millisecond.
pub const step_bytes: usize = if (build_options.gc_stress) 4 << 10 else 128 << 10;
pub const step_mul: usize = 4;
const mark_budget: usize = if (build_options.gc_stress) 64 else step_bytes * step_mul / 16;
const sweep_budget: usize = if (build_options.gc_stress) 64 else step_bytes * step_mul / 256;

/// Whether cycles run in steps; off, each cycle is done at once at the
/// safe point that starts it (as a stop-the-world collector).
pub const incremental = true;

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

    pub const vtable: std.mem.Allocator.VTable = .{
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
    pub fn trim(self: *CountingAllocator, keep: usize, max_blocks: usize) void {
        var c: usize = classes;
        var left = max_blocks;
        while (self.pooled > keep and c > 0 and left > 0) {
            c -= 1;
            while (self.pooled > keep and left > 0) {
                left -= 1;
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
        self.trim(0, std.math.maxInt(usize));
    }
};

/// Called by the interpreter at safe points. An isolate being killed sets
/// next_gc to 0, so the interrupt check costs nothing on the fast path.
pub inline fn safePoint(vm: *VM, th: *Thread) root.Error!void {
    if (vm.bytes_allocated >= vm.next_gc) try slowPoint(vm, th);
}

// (out of line: the fast path, one compare, is in every call and loop)
noinline fn slowPoint(vm: *VM, th: *Thread) root.Error!void {
    @branchHint(.cold);
    _ = th;
    if (vm.interrupt.load(.seq_cst)) return vm.raise("isolate killed", .{});
    step(vm);
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

// ------------------------------------------------------------ the state

pub const Phase = enum { idle, mark, sweep };

/// The color of a reached object; 0 and 1 are the two whites.
pub const black: u8 = 2;

/// The collector between its steps.
pub const State = struct {
    phase: Phase = .idle,
    /// the white new objects get (the other one is dead while sweeping)
    white: u8 = 0,
    /// reached objects whose references are not marked yet
    gray: std.ArrayList(*Object) = .empty,
    /// the weak-keyed tables reached, for converge
    ephemerons: std.ArrayList(*Table) = .empty,
    /// the threads reached, rescanned in the atomic step
    threads: std.ArrayList(*Thread) = .empty,
    /// the link to the next object the sweep looks at
    sweep_at: ?*?*Object = null,
    /// a large table scanned over several steps, and how far its list and
    /// hash parts are scanned (an element that moves back past these is
    /// marked by the barrier, see Table.removeShifting and compact)
    partial: ?*Table = null,
    partial_arr: usize = 0,
    partial_ents: usize = 0,
    /// the longest pause a step (or slang/vm's collect) made, in ns, since
    /// slang/vm's gc.longest_step was last reset
    longest_ns: u64 = 0,

    pub fn deinit(st: *State, gpa: Allocator) void {
        st.gray.deinit(gpa);
        st.ephemerons.deinit(gpa);
        st.threads.deinit(gpa);
    }
};

/// The color an object made now gets.
pub inline fn newColor(vm: *const VM) u8 {
    return vm.gc_state.white;
}

// ------------------------------------------------------------ the barrier

/// After storing v into holder: while marking, a value stored into a
/// reached object is reached too.
pub inline fn barrier(vm: *VM, holder: *Object, v: Value) void {
    if (holder.color == black) barrierSlow(vm, v);
}

noinline fn barrierSlow(vm: *VM, v: Value) void {
    @branchHint(.cold);
    if (vm.gc_state.phase == .mark) markValue(vm, v);
}

/// The barrier for table.zig, which has the allocator, not the VM: the VM's
/// allocator is its counting allocator, a field of the VM (other
/// allocators are tables outside any VM, in tests).
pub noinline fn tableBarrier(gpa: Allocator, holder: *Object, v: Value) void {
    @branchHint(.cold);
    if (gpa.vtable != &CountingAllocator.vtable) return;
    const c: *CountingAllocator = @ptrCast(@alignCast(gpa.ptr));
    const vm: *VM = @alignCast(@fieldParentPtr("counting", c));
    if (holder.color == black and vm.gc_state.phase == .mark) markValue(vm, v);
}

/// An interned string found again while sweeping may be dead and not yet
/// swept: it lives on (the sweep keeps it).
pub inline fn reviveString(vm: *VM, s: *String) void {
    const st = &vm.gc_state;
    if (st.phase == .sweep and s.obj.color == 1 - st.white) s.obj.color = st.white;
}

// ------------------------------------------------------------ marking

/// Whether a weak table can lose an entry to this value: strings, numbers
/// and the like are values, never collected out of one.
fn collectable(v: Value) bool {
    const o = v.heapObject() orelse return false;
    return o.kind != .string;
}

fn isMarked(v: Value) bool {
    const o = v.heapObject() orelse return true;
    return o.color == black;
}

fn markValue(vm: *VM, v: Value) void {
    if (v.heapObject()) |o| markObject(vm, o);
}

fn markObject(vm: *VM, o: *Object) void {
    if (o.color == black) return;
    o.color = black;
    if (o.kind == .string) return; // leaf
    vm.gc_state.gray.append(vm.gpa, o) catch oom();
}

fn markTable(vm: *VM, t: ?*Table) void {
    if (t) |p| markObject(vm, &p.obj);
}

fn markRoots(vm: *VM) void {
    markTable(vm, vm.globals);
    markTable(vm, vm.packages);
    markTable(vm, vm.registry);
    markObject(vm, &vm.main.obj);
    // a pending error's raised value
    if (vm.err) |e| markValue(vm, e.value);
    if (vm.ffi.pending) |e| markValue(vm, e.value);
    var foreign = vm.ffi.foreign.valueIterator();
    while (foreign.next()) |t| markObject(vm, &t.*.obj);
    for (vm.ffi.calls.items) |c| markObject(vm, &c.th.obj);
    if (vm.finalizer_thread) |t| markObject(vm, &t.obj);
    for (vm.pending_finalizers.items) |p| {
        markValue(vm, p.obj);
        markValue(vm, p.f);
    }
}

fn scanThread(vm: *VM, th: *Thread) usize {
    for (th.stack[0..th.top]) |v| markValue(vm, v);
    for (th.frames.items) |fr| markObject(vm, &fr.cl.obj);
    for (th.open_upvals.items) |u| markObject(vm, &u.obj);
    if (th.entry) |e| markObject(vm, &e.obj);
    markValue(vm, th.yielded);
    return th.top + th.frames.items.len + th.open_upvals.items.len;
}

/// Marks what o refers to; the work done, in slots.
fn blacken(vm: *VM, o: *Object) usize {
    switch (o.kind) {
        .string => return 1,
        .table => {
            const t: *Table = @alignCast(@fieldParentPtr("obj", o));
            markTable(vm, t.meta);
            switch (t.weak) {
                .none => {
                    for (t.arr.items) |v| markValue(vm, v);
                    for (t.ents.items) |e| {
                        markValue(vm, e.key);
                        markValue(vm, e.val);
                    }
                },
                // the values only when they cannot be collected
                .values => {
                    for (t.arr.items) |v| {
                        if (!collectable(v)) markValue(vm, v);
                    }
                    for (t.ents.items) |e| {
                        markValue(vm, e.key);
                        if (!collectable(e.val)) markValue(vm, e.val);
                    }
                },
                // a value once its key is alive (see converge)
                .keys => {
                    for (t.arr.items) |v| markValue(vm, v);
                    for (t.ents.items) |e| {
                        if (!collectable(e.key)) {
                            markValue(vm, e.key);
                            markValue(vm, e.val);
                        }
                    }
                    vm.gc_state.ephemerons.append(vm.gpa, t) catch oom();
                },
            }
            return 1 + t.arr.items.len + 2 * t.ents.items.len;
        },
        .closure => {
            const c: *Closure = @alignCast(@fieldParentPtr("obj", o));
            if (c.proto) |p| markObject(vm, &p.obj);
            for (c.upvals) |u| markObject(vm, &u.obj);
            if (c.name) |n| markObject(vm, &n.obj);
            for (c.nvals) |v| markValue(vm, v);
            return 1 + c.upvals.len + c.nvals.len;
        },
        .upvalue => {
            const u: *Upvalue = @alignCast(@fieldParentPtr("obj", o));
            if (u.th) |th| markObject(vm, &th.obj) else markValue(vm, u.v);
            return 1;
        },
        .userdata => {
            const u: *Userdata = @alignCast(@fieldParentPtr("obj", o));
            markTable(vm, u.meta);
            markValue(vm, u.owner);
            markValue(vm, u.keep);
            return 1;
        },
        .proto => {
            const p: *Proto = @alignCast(@fieldParentPtr("obj", o));
            for (p.consts) |v| markValue(vm, v);
            for (p.upvals) |u| markObject(vm, &u.name.obj);
            for (p.locs) |l| markObject(vm, &l.origin.obj);
            for (p.locals) |l| markObject(vm, &l.name.obj);
            if (p.name) |n| markObject(vm, &n.obj);
            for (p.children) |c| markObject(vm, &c.obj);
            return 1 + p.consts.len + p.locs.len + p.locals.len + p.children.len;
        },
        .thread => {
            const th: *Thread = @alignCast(@fieldParentPtr("obj", o));
            vm.gc_state.threads.append(vm.gpa, th) catch oom();
            return 1 + scanThread(vm, th);
        },
    }
}

/// A table with more slots than this is scanned in parts, over steps.
const large_table: usize = if (build_options.gc_stress) 32 else 4096;

/// Scans the partial table for up to budget slots; the slots used.
fn scanPartial(vm: *VM, budget: usize) usize {
    const st = &vm.gc_state;
    const t = st.partial.?;
    var used: usize = 0;
    // (the list part can grow while the hash part is scanned: fixList)
    while (used < budget) {
        if (st.partial_arr < t.arr.items.len) {
            markValue(vm, t.arr.items[st.partial_arr]);
            st.partial_arr += 1;
            used += 1;
        } else if (st.partial_ents < t.ents.items.len) {
            const e = t.ents.items[st.partial_ents];
            markValue(vm, e.key);
            markValue(vm, e.val);
            st.partial_ents += 1;
            used += 2;
        } else {
            st.partial = null;
            break;
        }
    }
    return used;
}

/// Marks until the gray list is empty or budget slots are scanned; whether
/// it is empty.
fn markSome(vm: *VM, budget: usize) bool {
    const st = &vm.gc_state;
    var left = budget;
    while (left > 0) {
        if (st.partial != null) {
            left -|= scanPartial(vm, left);
            continue;
        }
        const o = st.gray.pop() orelse return true;
        if (o.kind == .table) {
            const t: *Table = @alignCast(@fieldParentPtr("obj", o));
            if (t.weak == .none and t.arr.items.len + 2 * t.ents.items.len > large_table) {
                markTable(vm, t.meta);
                st.partial = t;
                st.partial_arr = 0;
                st.partial_ents = 0;
                continue;
            }
        }
        left -|= blacken(vm, o);
    }
    return st.partial == null and st.gray.items.len == 0;
}

fn drain(vm: *VM) void {
    _ = markSome(vm, std.math.maxInt(usize));
}

/// Marks until nothing new is reached through what only counts when its
/// holder is alive: the value of a weak key that is, and the finalizer of a
/// registered object that is.
fn converge(vm: *VM) void {
    while (true) {
        for (vm.gc_state.ephemerons.items) |t| {
            for (t.ents.items) |e| {
                if (collectable(e.key) and isMarked(e.key) and !isMarked(e.val)) markValue(vm, e.val);
            }
        }
        var it = vm.finalizers.valueIterator();
        while (it.next()) |f| {
            if (isMarked(f.obj) and !isMarked(f.f)) markValue(vm, f.f);
        }
        if (vm.gc_state.gray.items.len == 0) return;
        drain(vm);
    }
}

/// Removes the entries of the weak tables reached whose weak key or value
/// was not.
fn clearWeak(vm: *VM) void {
    var dead: std.ArrayList(Value) = .empty;
    defer dead.deinit(vm.gpa);
    for (vm.weak_tables.items) |t| {
        if (t.obj.color != black) continue;
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

/// The end of marking, in one go: what changed without a barrier (the
/// roots, the stacks) is marked again, weak tables and finalizers are
/// settled, and the whites swap.
fn atomic(vm: *VM) void {
    const st = &vm.gc_state;
    markRoots(vm);
    // (scanThread does not add to the list; threads reached now are
    // scanned when they are blackened)
    var i: usize = 0;
    while (i < st.threads.items.len) : (i += 1) _ = scanThread(vm, st.threads.items[i]);
    drain(vm);
    converge(vm);
    clearWeak(vm);

    // the unreachable registered objects: kept for their finalizers
    var dying: std.ArrayList(*Object) = .empty;
    defer dying.deinit(vm.gpa);
    var it = vm.finalizers.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*.color != black) dying.append(vm.gpa, e.key_ptr.*) catch oom();
    }
    for (dying.items) |o| {
        const f = vm.finalizers.fetchRemove(o).?.value;
        vm.pending_finalizers.append(vm.gpa, f) catch oom();
        markValue(vm, f.obj);
        markValue(vm, f.f);
    }
    if (dying.items.len > 0) {
        drain(vm);
        converge(vm);
        // (weak tables reached only through what was kept)
        clearWeak(vm);
    }
    // the weak tables that go now
    var keep: usize = 0;
    for (vm.weak_tables.items) |t| {
        if (t.obj.color == black) {
            vm.weak_tables.items[keep] = t;
            keep += 1;
        }
    }
    vm.weak_tables.shrinkRetainingCapacity(keep);
    if (build_options.gc_stress) verify(vm);

    st.threads.clearRetainingCapacity();
    st.ephemerons.clearRetainingCapacity();
    st.white = 1 - st.white;
    st.phase = .sweep;
    st.sweep_at = &vm.objects;
}

/// The GC-stress build's check after the atomic step: a reached object
/// refers to reached objects only (a store that missed the barrier shows
/// here, not as a crash much later).
fn verify(vm: *VM) void {
    var at = vm.objects;
    while (at) |o| : (at = o.next) {
        if (o.color != black) continue;
        switch (o.kind) {
            .string => {},
            .table => {
                const t: *Table = @alignCast(@fieldParentPtr("obj", o));
                if (t.meta) |m| expect(o, &m.obj);
                for (t.arr.items) |v| expectValue(o, v);
                for (t.ents.items) |e| {
                    expectValue(o, e.key);
                    expectValue(o, e.val);
                }
            },
            .closure => {
                const c: *Closure = @alignCast(@fieldParentPtr("obj", o));
                if (c.proto) |p| expect(o, &p.obj);
                for (c.upvals) |u| expect(o, &u.obj);
                for (c.nvals) |v| expectValue(o, v);
            },
            .upvalue => {
                const u: *Upvalue = @alignCast(@fieldParentPtr("obj", o));
                if (u.th) |th| expect(o, &th.obj) else expectValue(o, u.v);
            },
            .userdata => {
                const u: *Userdata = @alignCast(@fieldParentPtr("obj", o));
                if (u.meta) |m| expect(o, &m.obj);
                expectValue(o, u.owner);
                expectValue(o, u.keep);
            },
            .proto => {
                const p: *Proto = @alignCast(@fieldParentPtr("obj", o));
                for (p.consts) |v| expectValue(o, v);
                for (p.children) |c| expect(o, &c.obj);
            },
            .thread => {
                const th: *Thread = @alignCast(@fieldParentPtr("obj", o));
                for (th.stack[0..th.top]) |v| expectValue(o, v);
                for (th.frames.items) |fr| expect(o, &fr.cl.obj);
                for (th.open_upvals.items) |u| expect(o, &u.obj);
            },
        }
    }
}

fn expectValue(holder: *Object, v: Value) void {
    if (v.heapObject()) |o| expect(holder, o);
}

fn expect(holder: *Object, o: *Object) void {
    if (o.color != black) std.debug.panic("gc: a reached {t} refers to an unreached {t} (a store without the write barrier)", .{ holder.kind, o.kind });
}

// ------------------------------------------------------------ sweeping

/// Frees up to budget dead objects (the old white) and gives survivors the
/// new white; whether the sweep is done.
fn sweepSome(vm: *VM, budget: usize) bool {
    const st = &vm.gc_state;
    const dead = 1 - st.white;
    var link = st.sweep_at.?;
    var left = budget;
    while (link.*) |o| {
        if (left == 0) {
            st.sweep_at = link;
            return false;
        }
        left -= 1;
        if (o.color == dead) {
            link.* = o.next;
            freeObject(vm, o);
        } else {
            o.color = st.white;
            link = &o.next;
        }
    }
    st.sweep_at = null;
    return true;
}

fn finishCycle(vm: *VM) void {
    vm.gc_state.phase = .idle;
    vm.last_live = vm.bytes_allocated;
    vm.compactStrings();
    // the pools keep what the next cycle's allocations will likely reuse:
    // up to half the live size (and at least the minimum's worth); a few
    // thousand blocks per cycle, so that this is no pause of its own
    vm.counting.trim(@max(vm.bytes_allocated / 2, vm.gc_minimum / 2), 2048);
    vm.collections += 1;
}

// ------------------------------------------------------------ steps

/// Does a step's work, or (budget null) everything up to the end of the
/// cycle.
fn advance(vm: *VM, bounded: bool) void {
    const st = &vm.gc_state;
    if (st.phase == .idle) {
        st.phase = .mark;
        markRoots(vm);
    }
    if (st.phase == .mark) {
        if (!markSome(vm, if (bounded) mark_budget else std.math.maxInt(usize))) return;
        atomic(vm);
        if (bounded) return;
    }
    if (st.phase == .sweep and sweepSome(vm, if (bounded) sweep_budget else std.math.maxInt(usize))) {
        finishCycle(vm);
    }
}

/// The automatic step at a safe point: a cycle's next step (or the whole
/// cycle when not incremental), then the next one scheduled.
pub fn step(vm: *VM) void {
    if (vm.gc_running) return;
    vm.gc_running = true;
    defer vm.gc_running = false;
    const t0 = std.Io.Clock.now(.awake, vm.io);
    // the GC-stress build alternates: a cycle at once (garbage freed
    // early, what a native held without a root shows), then one in tiny
    // steps (what a store without the barrier left shows, see verify)
    const bounded = incremental and (!build_options.gc_stress or vm.collections % 2 == 1 or vm.gc_state.phase != .idle);
    advance(vm, bounded);
    measure(vm, t0);
    schedule(vm);
}

fn measure(vm: *VM, t0: std.Io.Timestamp) void {
    const ns = t0.durationTo(std.Io.Clock.now(.awake, vm.io)).nanoseconds;
    const n: u64 = if (ns > 0) @intCast(ns) else 0;
    if (n > vm.gc_state.longest_ns) vm.gc_state.longest_ns = n;
}

/// slang/vm's gc:step(ms): collector work for up to ms (a program's idle
/// time, a game's end of frame), in steps; a cycle starts here only once
/// the heap has grown half way to the next automatic one. Whether a cycle
/// is still running.
pub fn stepFor(vm: *VM, ms: f64) bool {
    if (vm.gc_running) return vm.gc_state.phase != .idle;
    const st = &vm.gc_state;
    if (st.phase == .idle) {
        const last = vm.last_live;
        if (vm.bytes_allocated < last + (vm.next_gc -| last) / 2) return false;
    }
    vm.gc_running = true;
    defer vm.gc_running = false;
    const t0 = std.Io.Clock.now(.awake, vm.io);
    const budget: i96 = @intFromFloat(@max(ms, 0) * 1e6);
    while (true) {
        advance(vm, true);
        if (st.phase == .idle) break;
        if (t0.durationTo(std.Io.Clock.now(.awake, vm.io)).nanoseconds >= budget) break;
    }
    schedule(vm);
    return st.phase != .idle;
}

/// slang/vm's collect(): a running cycle is finished, then a whole one runs,
/// so that everything unreachable now is gone.
pub fn collect(vm: *VM) void {
    if (vm.gc_running) return;
    vm.gc_running = true;
    defer vm.gc_running = false;
    while (vm.gc_state.phase != .idle) advance(vm, false);
    advance(vm, false);
    schedule(vm);
}

/// Sets the threshold of the next automatic collection from the settings
/// and the live size: after a collection, and when the settings change.
pub fn schedule(vm: *VM) void {
    const next: usize = if (!vm.gc_automatic)
        std.math.maxInt(usize)
    else if (vm.gc_state.phase != .idle)
        // a cycle runs: its next step
        vm.bytes_allocated + step_bytes
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
