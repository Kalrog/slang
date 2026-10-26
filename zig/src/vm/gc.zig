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
//! the next one happens when the live size has doubled.

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
/// In stress mode a collection runs as soon as this much has been
/// allocated since the previous one.
pub const stress_step: usize = 64 << 10;

/// Wraps the backing allocator and keeps vm.bytes_allocated exact.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    counter: *usize,

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
        const p = self.backing.vtable.alloc(self.backing.ptr, len, alignment, ret_addr);
        if (p != null) self.counter.* += len;
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.vtable.resize(self.backing.ptr, memory, alignment, new_len, ret_addr)) return false;
        self.counter.* = self.counter.* + new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.backing.vtable.remap(self.backing.ptr, memory, alignment, new_len, ret_addr);
        if (p != null) self.counter.* = self.counter.* + new_len - memory.len;
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.vtable.free(self.backing.ptr, memory, alignment, ret_addr);
        self.counter.* -= memory.len;
    }
};

/// Called by the interpreter at safe points.
pub inline fn safePoint(vm: *VM, th: *Thread) void {
    _ = th;
    if (vm.bytes_allocated >= vm.next_gc) collect(vm);
}

const Marker = struct {
    vm: *VM,
    gray: std.ArrayList(*Object),

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
                const t: *Table = @fieldParentPtr("obj", o);
                for (t.arr.items) |v| m.markValue(v);
                for (t.ents.items) |e| {
                    m.markValue(e.key);
                    m.markValue(e.val);
                }
                m.markTable(t.meta);
            },
            .closure => {
                const c: *Closure = @fieldParentPtr("obj", o);
                if (c.proto) |p| m.markObject(&p.obj);
                for (c.upvals) |u| m.markObject(&u.obj);
                if (c.name) |n| m.markObject(&n.obj);
                for (c.nvals) |v| m.markValue(v);
            },
            .upvalue => {
                const u: *Upvalue = @fieldParentPtr("obj", o);
                if (u.th) |th| m.markObject(&th.obj) else m.markValue(u.v);
            },
            .userdata => {
                const u: *Userdata = @fieldParentPtr("obj", o);
                m.markTable(u.meta);
            },
            .proto => {
                const p: *Proto = @fieldParentPtr("obj", o);
                for (p.consts) |v| m.markValue(v);
                for (p.upvals) |u| m.markObject(&u.name.obj);
                for (p.locs) |l| m.markObject(&l.origin.obj);
                for (p.children) |c| m.markObject(&c.obj);
            },
            .thread => {
                const th: *Thread = @fieldParentPtr("obj", o);
                for (th.stack[0..th.top]) |v| m.markValue(v);
                for (th.frames.items) |fr| m.markObject(&fr.cl.obj);
                for (th.open_upvals.items) |u| m.markObject(&u.obj);
                if (th.entry) |e| m.markObject(&e.obj);
                m.markValue(th.yielded);
            },
        }
    }
};

pub fn collect(vm: *VM) void {
    if (vm.gc_running) return;
    vm.gc_running = true;
    defer vm.gc_running = false;

    var m: Marker = .{ .vm = vm, .gray = .empty };
    defer m.gray.deinit(vm.gpa);
    m.markTable(vm.globals);
    m.markTable(vm.packages);
    m.markTable(vm.registry);
    m.markObject(&vm.main.obj);
    m.drain();

    sweep(vm);
    vm.collections += 1;
    vm.next_gc = if (build_options.gc_stress)
        vm.bytes_allocated + stress_step
    else
        @max(initial_threshold, vm.bytes_allocated * 2);
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
            const s: *String = @fieldParentPtr("obj", o);
            if (s.interned) _ = vm.strings.remove(s);
            const mem: [*]align(@alignOf(String)) u8 = @ptrCast(s);
            gpa.free(mem[0..String.allocSize(s.len)]);
        },
        .table => {
            const t: *Table = @fieldParentPtr("obj", o);
            t.deinit(gpa);
            gpa.destroy(t);
        },
        .closure => {
            const c: *Closure = @fieldParentPtr("obj", o);
            gpa.free(c.upvals);
            gpa.free(c.nvals);
            gpa.destroy(c);
        },
        .upvalue => {
            const u: *Upvalue = @fieldParentPtr("obj", o);
            gpa.destroy(u);
        },
        .userdata => {
            const u: *Userdata = @fieldParentPtr("obj", o);
            if (u.finalizer) |f| f(u.data.ptr);
            gpa.free(@as([]align(16) u8, @alignCast(u.data)));
            gpa.destroy(u);
        },
        .proto => {
            const p: *Proto = @fieldParentPtr("obj", o);
            p.deinit(gpa);
            gpa.destroy(p);
        },
        .thread => {
            const t: *Thread = @fieldParentPtr("obj", o);
            t.deinit();
            gpa.destroy(t);
        },
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
