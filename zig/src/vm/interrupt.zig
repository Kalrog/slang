//! SIGINT as an error in running slang code (slang/vm's catch_interrupt):
//! what lets a REPL or a notebook's kernel stop the code it runs without
//! ending itself.
//!
//! The signal handler only writes a byte to a pipe. A thread of its own
//! reads it and marks the VM (gc.softInterrupt): the thread the interrupt
//! is meant for raises an error of kind "interrupted" at its next safe
//! point, and the interrupt hooks wake an event loop that is waiting.

const std = @import("std");
const builtin = @import("builtin");
const root = @import("../vm.zig");
const VM = root.VM;
const gc = @import("gc.zig");

/// No signals in a browser; Windows has its own way, not built yet.
pub const supported = !builtin.cpu.arch.isWasm() and builtin.os.tag != .windows;

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn signal(sig: c_int, handler: *const fn (c_int) callconv(.c) void) ?*anyopaque;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;

const SIGINT = 2;

var fds: [2]c_int = .{ -1, -1 };
var installed = false;
/// guards `watched` (a spin lock: held for moments, by two threads at most)
var lock: std.atomic.Value(bool) = .init(false);
/// the VM interrupts go to: the main VM once it asked for them
var watched: ?*VM = null;

fn acquire() void {
    while (lock.swap(true, .acquire)) {}
}

fn release() void {
    lock.store(false, .release);
}

fn onSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    const byte = [1]u8{1};
    _ = write(fds[1], &byte, 1);
}

fn watch() void {
    var buf: [16]u8 = undefined;
    while (true) {
        const n = read(fds[0], &buf, buf.len);
        if (n == 0) return;
        if (n < 0) continue;
        acquire();
        if (watched) |vm| gc.softInterrupt(vm);
        release();
    }
}

/// From now on SIGINT interrupts vm instead of ending the process.
pub fn install(vm: *VM) !void {
    if (comptime !supported) return error.Unsupported;
    acquire();
    defer release();
    watched = vm;
    if (installed) return;
    if (pipe(&fds) != 0) return error.Unexpected;
    const thread = try std.Thread.spawn(.{}, watch, .{});
    thread.detach();
    _ = signal(SIGINT, onSignal);
    installed = true;
}

/// vm is going away: no interrupt reaches it any more.
pub fn detach(vm: *VM) void {
    if (comptime !supported) return;
    acquire();
    defer release();
    if (watched == vm) watched = null;
}
