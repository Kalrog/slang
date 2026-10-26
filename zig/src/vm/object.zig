const std = @import("std");
const Value = @import("value.zig").Value;
const String = @import("string.zig").String;
const Table = @import("table.zig").Table;
const Thread = @import("thread.zig").Thread;
const Error = @import("errors.zig").Error;

/// Common header of every heap object. Objects are linked into one list
/// owned by the VM so the collector can sweep them.
pub const Object = struct {
    next: ?*Object = null,
    kind: ObjKind,
    marked: bool = false,
};

pub const ObjKind = enum(u8) { string, table, closure, upvalue, userdata, proto, thread };

/// A function implemented in Zig. `args` aliases the thread's value stack and
/// is only valid until the native calls back into the VM (`th.call`), which
/// may move the stack; natives that call back read their arguments again
/// through `th.arg(i)`.
pub const NativeFn = *const fn (th: *Thread, args: []Value) Error!Value;

/// A function implemented against slang.h (see capi.zig).
pub const CFunction = *const fn (th: *Thread) callconv(.c) c_int;

pub const Special = enum(u8) { none, pcall };

/// A callable value: a slang function (proto + captured upvalues) or a
/// native function (with optional closed-over values in `nvals`).
pub const Closure = struct {
    obj: Object,
    proto: ?*Proto = null,
    upvals: []*Upvalue = &.{},
    native: ?NativeFn = null,
    cfunc: ?CFunction = null,
    name: ?*String = null,
    nvals: []Value = &.{},
    special: Special = .none,

    pub fn isNative(c: *const Closure) bool {
        return c.proto == null;
    }

    pub fn nameBytes(c: *const Closure) []const u8 {
        return if (c.name) |n| n.bytes() else "?";
    }

    /// The index of the named upvalue, or null.
    pub fn upvalueIndex(c: *const Closure, name: []const u8) ?usize {
        const p = c.proto orelse return null;
        for (p.upvals, 0..) |u, i| {
            if (u.name.eqlBytes(name)) return i;
        }
        return null;
    }

    pub fn getUpvalue(c: *const Closure, i: usize) Value {
        if (i >= c.upvals.len) return .null;
        return c.upvals[i].get();
    }
};

/// A captured variable. While open it refers to a slot of a thread's stack;
/// once closed it owns the value.
pub const Upvalue = struct {
    obj: Object,
    th: ?*Thread = null,
    idx: usize = 0,
    v: Value = .null,

    pub fn get(u: *const Upvalue) Value {
        if (u.th) |th| return th.stack[u.idx];
        return u.v;
    }

    pub fn set(u: *Upvalue, v: Value) void {
        if (u.th) |th| {
            th.stack[u.idx] = v;
            return;
        }
        u.v = v;
    }

    pub fn close(u: *Upvalue) void {
        if (u.th) |th| {
            u.v = th.stack[u.idx];
            u.th = null;
        }
    }
};

pub const Finalizer = *const fn (data: ?*anyopaque) callconv(.c) void;
pub const ToStringFn = *const fn (u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void;

/// Opaque data owned by native code, with an optional metatable. The data
/// block is allocated by the VM and freed when the object is collected (after
/// the finalizer, if any, ran).
pub const Userdata = struct {
    obj: Object,
    meta: ?*Table = null,
    tname: []const u8,
    data: []u8,
    finalizer: ?Finalizer = null,
    to_string: ?ToStringFn = null,

    pub fn as(u: *Userdata, comptime T: type) *T {
        return @ptrCast(@alignCast(u.data.ptr));
    }
};

pub const UpvalDesc = struct {
    name: *String,
    index: u32,
    is_local: bool,
};

pub const LocInfo = struct {
    first_pc: u32,
    origin: *String,
    line: u32,
    column: u32,
};

/// A compiled function: bytecode plus everything needed to instantiate
/// closures from it. All slices are owned by the proto (freed on sweep).
pub const Proto = struct {
    obj: Object,
    code: []u32 = &.{},
    consts: []Value = &.{},
    upvals: []UpvalDesc = &.{},
    children: []*Proto = &.{},
    locs: []LocInfo = &.{},
    max_stack: u32 = 0,
    nargs: u32 = 0,
    is_vararg: bool = false,

    /// The source position of the instruction at pc, or null.
    pub fn location(p: *const Proto, pc: usize) ?*const LocInfo {
        var res: ?*const LocInfo = null;
        for (p.locs) |*l| {
            if (l.first_pc <= pc) res = l else break;
        }
        return res;
    }

    pub fn origin(p: *const Proto) []const u8 {
        if (p.locs.len > 0) return p.locs[0].origin.bytes();
        return "";
    }

    pub fn deinit(p: *Proto, gpa: std.mem.Allocator) void {
        gpa.free(p.code);
        gpa.free(p.consts);
        gpa.free(p.upvals);
        gpa.free(p.children);
        gpa.free(p.locs);
    }
};
