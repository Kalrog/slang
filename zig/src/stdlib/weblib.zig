//! slang/web: what a program needs from the browser, in the Emscripten
//! build only (the playground). A program there runs as a coroutine that
//! main.zig resumes once per animation frame.

const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const stdlib = @import("stdlib.zig");

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "frame", .f = webFrame },
    });
}

/// frame(): ends the frame: the browser shows what was drawn and handles
/// input, and the program goes on at the next animation frame. Called from
/// the program itself (not from a coroutine it made, and not under a native
/// callback).
fn webFrame(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return th.yield(.null);
}
