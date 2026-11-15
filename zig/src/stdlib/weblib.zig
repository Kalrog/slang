//! slang/web: what a program needs from the browser, in the Emscripten
//! build only (the playground). A program there runs as a coroutine that
//! main.zig resumes once per animation frame. Its page and it talk in
//! messages (text, usually JSON): send(text) calls the page's
//! Module.onProgramMessage(text), receive() takes the oldest text the page
//! put in Module.programInbox (website/web/bridge.c).

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

// website/web/bridge.c
extern fn slang_web_send(text: [*]const u8, len: usize) void;
extern fn slang_web_receive() ?[*:0]u8;
extern fn free(p: ?*anyopaque) void;

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "frame", .f = webFrame },
        .{ .name = "send", .f = webSend },
        .{ .name = "receive", .f = webReceive },
    });
}

/// send(text): a message to the page (Module.onProgramMessage(text))
fn webSend(th: *Thread, args: []Value) Error!Value {
    const text = try api.argString(th, args, 0, "text");
    slang_web_send(text.ptr, text.len);
    return .null;
}

/// receive() -> string?: the oldest message from the page (what it put in
/// Module.programInbox), or null when there is none
fn webReceive(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const p = slang_web_receive() orelse return .null;
    defer free(p);
    return th.vm.str(std.mem.span(p));
}

/// frame(): ends the frame: the browser shows what was drawn and handles
/// input, and the program goes on at the next animation frame. Called from
/// the program itself (not from a coroutine it made, and not under a native
/// callback).
fn webFrame(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return th.yield(.null);
}
