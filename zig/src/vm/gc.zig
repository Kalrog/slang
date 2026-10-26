//! Memory management. Phase 2 of the port: objects are allocated and linked
//! but never collected; `collect` only exists so the safe points are in
//! place. `freeAll` releases everything when the VM is destroyed.

const std = @import("std");
const build_options = @import("build_options");
const root = @import("../vm.zig");
const VM = root.VM;
const Thread = root.Thread;
const Object = root.Object;
const String = root.String;
const Table = root.Table;
const Closure = root.Closure;
const Upvalue = root.Upvalue;
const Userdata = root.Userdata;
const Proto = root.Proto;

pub const initial_threshold: usize = 8 << 20;

/// Called by the interpreter at safe points (every value the program can
/// still reach is on a thread stack, in a frame or in the globals).
pub inline fn safePoint(vm: *VM, th: *Thread) void {
    _ = th;
    if (build_options.gc_stress or vm.bytes_allocated >= vm.next_gc) collect(vm);
}

pub fn collect(vm: *VM) void {
    // Phase 3 implements mark and sweep here.
    vm.next_gc = vm.bytes_allocated * 2;
}

fn freeObject(vm: *VM, o: *Object) void {
    const gpa = vm.gpa;
    switch (o.kind) {
        .string => {
            const s: *String = @fieldParentPtr("obj", o);
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
