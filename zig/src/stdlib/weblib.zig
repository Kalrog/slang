//! slang/web: what a program needs from the browser, in the two builds that
//! run there. A program is a coroutine that main.zig resumes: in the
//! Emscripten build (the playground's graphics VM) once per animation
//! frame, in the WASI build (slang.wasm in a worker) whenever its page
//! says so (the export slang_resume). The page and the program talk in
//! messages (text, usually JSON): send(text) gives the page one, receive()
//! takes the oldest one the page sent.
//!
//! The Emscripten half of the messages is website/web/bridge.c
//! (Module.onProgramMessage, Module.programInbox); the WASI half are the
//! imports of the module "slang_host" (website/public/wasi.js).

const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

/// The builds that have a page: slang/web is a module there.
pub const present = builtin.os.tag == .emscripten or builtin.os.tag == .wasi;

const em = struct {
    // website/web/bridge.c
    extern fn slang_web_send(text: [*]const u8, len: usize) void;
    extern fn slang_web_receive() ?[*:0]u8;
    extern fn free(p: ?*anyopaque) void;
};

/// What the page of a WASI build provides (the imports of "slang_host").
pub const host = struct {
    /// a message for the page
    pub extern "slang_host" fn send(text: [*]const u8, len: usize) void;
    /// the bytes of the oldest message from the page, or -1 without one
    pub extern "slang_host" fn receive_size() i32;
    /// copies that message to `into` and drops it
    pub extern "slang_host" fn receive(into: [*]u8) void;
    /// the program yielded and waits to be resumed: _start is about to end
    pub extern "slang_host" fn parked() void;
    /// whether the page asked to stop what runs (asked once per request)
    pub extern "slang_host" fn interrupted() i32;
};

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "frame", .f = webFrame },
        .{ .name = "send", .f = webSend },
        .{ .name = "receive", .f = webReceive },
    });
}

/// send(text): a message to the page. What the program printed before it
/// reaches the page before it.
fn webSend(th: *Thread, args: []Value) Error!Value {
    const text = try api.argString(th, args, 0, "text");
    if (comptime builtin.os.tag == .wasi) {
        th.vm.flush();
        host.send(text.ptr, text.len);
    } else {
        em.slang_web_send(text.ptr, text.len);
    }
    return .null;
}

/// receive() -> string?: the oldest message from the page, or null when
/// there is none
fn webReceive(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    if (comptime builtin.os.tag == .wasi) {
        const size = host.receive_size();
        if (size < 0) return .null;
        const buf = vm.gpa.alloc(u8, @intCast(size)) catch vm_mod.oom();
        defer vm.gpa.free(buf);
        host.receive(buf.ptr);
        return vm.str(buf);
    }
    const p = em.slang_web_receive() orelse return .null;
    defer em.free(p);
    return vm.str(std.mem.span(p));
}

/// frame(): hands the page control: in the graphics VM the browser shows
/// what was drawn and the program goes on at the next animation frame; in
/// a worker the program goes on when the page resumes it (it sent a
/// message, say). Called from the program itself (not from a coroutine it
/// made, and not under a native callback).
fn webFrame(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return th.yield(.null);
}
