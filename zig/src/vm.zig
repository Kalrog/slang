//! The slang virtual machine: values, heap objects, the interpreter, threads
//! (coroutines) and the native-function API used by the standard library.
//! Everything written in slang (compiler, libraries) runs on top of this.

pub const Value = @import("vm/value.zig").Value;
pub const Kind = @import("vm/value.zig").Kind;
pub const String = @import("vm/string.zig").String;
pub const Table = @import("vm/table.zig").Table;
pub const Closure = @import("vm/object.zig").Closure;
pub const Upvalue = @import("vm/object.zig").Upvalue;
pub const Userdata = @import("vm/object.zig").Userdata;
pub const UserKind = @import("vm/object.zig").UserKind;
pub const Proto = @import("vm/object.zig").Proto;
pub const Object = @import("vm/object.zig").Object;
pub const NativeFn = @import("vm/object.zig").NativeFn;
pub const Thread = @import("vm/thread.zig").Thread;
pub const Status = @import("vm/thread.zig").Status;
pub const Scratch = @import("vm/scratch.zig").Scratch;
pub const VM = @import("vm/vm.zig").VM;
pub const EmbeddedFile = @import("vm/vm.zig").EmbeddedFile;
pub const Error = @import("vm/errors.zig").Error;
pub const SlangError = @import("vm/errors.zig").SlangError;
pub const Location = @import("vm/errors.zig").Location;
pub const slb = @import("vm/slb.zig");
pub const disasm = @import("vm/disasm.zig");
pub const format = @import("vm/format.zig");
pub const api = @import("vm/api.zig");
pub const gc = @import("vm/gc.zig");
pub const Profiler = @import("vm/profile.zig").Profiler;
pub const Debugger = @import("vm/debug.zig").Debugger;

/// Allocation failure is fatal: a scripting VM cannot recover from it in any
/// useful way, and threading OutOfMemory through every operation would make
/// the interpreter unreadable.
pub fn oom() noreturn {
    @panic("out of memory");
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("vm/table.zig");
    _ = @import("vm/format.zig");
}
