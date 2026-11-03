//! slang/ctypes: C types and C memory, in every build (no libffi here;
//! slang/ffi_core adds calls). slang/ffi and slang/buffer build on it.
//!
//! Types: scalars, pointers, arrays and structs laid out by C's rules. A
//! type also carries a libffi type descriptor, filled in here (libffi only
//! reads its size, alignment, type code and elements), so ffi_core can call
//! with it.
//!
//! Memory comes in two kinds of userdata with one layout ({addr, ty,
//! count}):
//!   a pointer: an address as C hands it out, no length. p[i] reads element
//!     i (a pointer to it when it is a struct), p.field a field of the struct
//!     p points to; both write with assignment.
//!   a buffer: an address with a count, owned (new memory the collector
//!     frees), a slice of another buffer (keeping it alive), or wrapping C
//!     memory of a known length. b[i] is checked against the count; string
//!     keys are methods. The VM indexes buffers of scalars without a call
//!     (bufferGet and bufferSet below).
//!
//! Values convert as follows (slang -> C, and back):
//!   bool and the integer and float types: numbers (and bools)
//!   string (const char *): a string, valid during a call; back a copy
//!   pointer: null, a pointer or buffer, a string (its bytes, during a
//!     call), or a table: a list of elements or one struct, copied to
//!     temporary memory and, when asked, copied back after the call
//!   struct: a table (fields by name, else by position) or a pointer to one
//!     of the same type; back a table with the fields by name
//!   array (in structs): a list, or a string for char arrays
//!
//! Types are never freed (declarations live as long as the program).

const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Scratch = vm_mod.Scratch;
const String = vm_mod.String;
const Thread = vm_mod.Thread;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

// ------------------------------------------------------------ type descriptors

/// libffi's ffi_type, laid out the same way.
pub const FfiType = extern struct {
    size: usize,
    alignment: c_ushort,
    type: c_ushort,
    elements: ?[*]?*FfiType,
};

// libffi's type codes
const T_VOID = 0;
const T_FLOAT = 2;
const T_DOUBLE = 3;
const T_UINT8 = 5;
const T_SINT8 = 6;
const T_UINT16 = 7;
const T_SINT16 = 8;
const T_UINT32 = 9;
const T_SINT32 = 10;
const T_UINT64 = 11;
const T_SINT64 = 12;
const T_STRUCT = 13;
const T_POINTER = 14;

fn desc(size: usize, code: c_ushort) FfiType {
    return .{ .size = size, .alignment = @intCast(@max(size, 1)), .type = code, .elements = null };
}

var d_void = FfiType{ .size = 1, .alignment = 1, .type = T_VOID, .elements = null };
var d_u8 = desc(1, T_UINT8);
var d_i8 = desc(1, T_SINT8);
var d_u16 = desc(2, T_UINT16);
var d_i16 = desc(2, T_SINT16);
var d_u32 = desc(4, T_UINT32);
var d_i32 = desc(4, T_SINT32);
var d_u64 = desc(8, T_UINT64);
var d_i64 = desc(8, T_SINT64);
var d_f32 = desc(4, T_FLOAT);
var d_f64 = desc(8, T_DOUBLE);
var d_ptr = desc(@sizeOf(usize), T_POINTER);

// ------------------------------------------------------------ types

pub const Kind = enum { void, bool, i8, u8, i16, u16, i32, u32, i64, u64, f32, f64, pointer, string, @"struct", array, function };

/// The signature of a function pointer type: what C passes a callback and
/// what it expects back.
pub const Signature = struct { ret: *Type, args: []*Type };

/// Makes a slang function callable from C as a function pointer of type t
/// (a callback; set by slang/ffi_core, which has libffi). The address lives
/// as long as the program; the same function and type give the same one.
pub var make_callback: ?*const fn (th: *Thread, f: Value, t: *Type) Error!usize = null;

/// default: the value of a field a table leaves out (0 otherwise)
pub const Field = struct {
    name: []const u8,
    offset: usize,
    ty: *Type,
    default: ?Value = null,
    /// the name interned, so a table converts with pointer compares
    key: *String,
};

pub const Type = struct {
    kind: Kind,
    size: usize,
    alignment: usize,
    /// for messages: "int", "Vector2", "Vector2 *"
    name: []const u8,
    ffi: *FfiType,
    /// the target of a pointer, the element of an array
    elem: ?*Type = null,
    count: usize = 0,
    fields: []Field = &.{},
    /// a struct declared but not defined yet (struct X;)
    complete: bool = true,
    /// char: an int8 whose arrays are strings
    char: bool = false,
    /// a function pointer's signature
    sig: ?*Signature = null,

    pub fn isScalar(t: *const Type) bool {
        return switch (t.kind) {
            .bool, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .f32, .f64 => true,
            else => false,
        };
    }

    /// a pointer to bytes (void *, char *, uint8_t *): any memory goes
    fn takesBytes(t: *const Type) bool {
        const e = t.elem orelse return true;
        return e.kind == .void or e.char or e.kind == .i8 or e.kind == .u8;
    }
};

/// Whether memory of type a can be read as type b: the same type, or
/// scalars of the same kind (each primitive() call makes its own value).
pub fn sameType(a: *const Type, b: *const Type) bool {
    if (a == b) return true;
    if (a.isScalar() and b.isScalar()) return a.kind == b.kind;
    return false;
}

pub const type_tname = "ffi.type";
pub const pointer_tname = "ffi.pointer";
pub const buffer_tname = "buffer";


/// Pointers and buffers: an address, what it points to (null for void *)
/// and, for a buffer, the number of elements. Owned memory follows this
/// header in the same userdata block.
pub const Ptr = struct {
    addr: usize,
    ty: ?*Type,
    count: usize = 0,
    /// a C function that frees what the pointer points to, called when the
    /// pointer object is collected (slang/ffi's gc)
    free: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

/// The finalizer of a pointer given a free function by slang/ffi's gc.
pub fn freePointer(data: ?*anyopaque) callconv(.c) void {
    const p: *Ptr = @ptrCast(@alignCast(data.?));
    if (p.free) |f| f(@ptrFromInt(p.addr));
}

pub fn module(vm: *VM) *Table {
    const m = stdlib.makeModule(vm, &.{
        .{ .name = "primitive", .f = ctPrimitive },
        .{ .name = "pointer", .f = ctPointer },
        .{ .name = "function", .f = ctFunction },
        .{ .name = "array", .f = ctArray },
        .{ .name = "struct", .f = ctStruct },
        .{ .name = "define", .f = ctDefine },
        .{ .name = "sizeof", .f = ctSizeof },
        .{ .name = "offsetof", .f = ctOffsetof },
        .{ .name = "type_name", .f = ctTypeName },
        .{ .name = "new", .f = ctNew },
        .{ .name = "cast", .f = ctCast },
        .{ .name = "offset", .f = ctOffset },
        .{ .name = "address", .f = ctAddress },
        .{ .name = "string", .f = ctString },
        .{ .name = "value", .f = ctValue },
        .{ .name = "buffer", .f = ctBuffer },
        .{ .name = "buffer_from", .f = ctBufferFrom },
        .{ .name = "wrap", .f = ctWrap },
        .{ .name = "is_buffer", .f = ctIsBuffer },
        .{ .name = "shared_buffer", .f = ctSharedBuffer },
    });
    const tm = vm.newTable(0, 2);
    tm.set(vm.gpa, vm.str("__type"), vm.str(type_tname));
    vm.lib.type_meta = tm;
    vm.registry.set(vm.gpa, vm.str("ctypes_type_meta"), .{ .table = tm });

    const pm = vm.newTable(0, 4);
    pm.set(vm.gpa, vm.str("__index"), vm.nativeValue("ffi.pointer.__index", ptrIndex));
    pm.set(vm.gpa, vm.str("__newindex"), vm.nativeValue("ffi.pointer.__newindex", ptrNewIndex));
    pm.set(vm.gpa, vm.str("__eq"), vm.nativeValue("ffi.pointer.__eq", ptrEq));
    pm.set(vm.gpa, vm.str("__type"), vm.str(pointer_tname));
    vm.lib.pointer_meta = pm;
    vm.registry.set(vm.gpa, vm.str("ctypes_pointer_meta"), .{ .table = pm });

    const methods = stdlib.makeModule(vm, &.{
        .{ .name = "slice", .f = bufSlice },
        .{ .name = "copy", .f = bufCopy },
        .{ .name = "fill", .f = bufFill },
        .{ .name = "set", .f = bufSet },
        .{ .name = "cast", .f = bufCast },
        .{ .name = "to_list", .f = bufToList },
        .{ .name = "to_string", .f = bufToString },
        .{ .name = "same", .f = bufSame },
        .{ .name = "pointer", .f = bufPointer },
        .{ .name = "lock", .f = bufLock },
        .{ .name = "unlock", .f = bufUnlock },
    });
    vm.lib.buffer_methods = methods;
    const bm = vm.newTable(0, 6);
    bm.set(vm.gpa, vm.str("__index"), vm.nativeValue("buffer.__index", bufIndex));
    bm.set(vm.gpa, vm.str("__newindex"), vm.nativeValue("buffer.__newindex", bufNewIndex));
    bm.set(vm.gpa, vm.str("__eq"), vm.nativeValue("buffer.__eq", bufEq));
    bm.set(vm.gpa, vm.str("__len"), vm.nativeValue("buffer.__len", bufLen));
    bm.set(vm.gpa, vm.str("__type"), vm.str(buffer_tname));
    bm.set(vm.gpa, vm.str("methods"), .{ .table = methods });
    vm.lib.buffer_meta = bm;
    vm.registry.set(vm.gpa, vm.str("ctypes_buffer_meta"), .{ .table = bm });
    return m;
}

fn newType(vm: *VM, t: Type) *Type {
    const p = vm.gpa.create(Type) catch oom();
    p.* = t;
    return p;
}

pub fn typeValue(vm: *VM, t: *Type) Value {
    const u = vm.newUserdataOf(*Type, t, type_tname, vm.lib.type_meta);
    u.to_string = typeToString;
    return .{ .userdata = u };
}

fn typeToString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("ffi.type<{s}>", .{u.as(*Type).*.name});
}

pub fn asType(v: Value) ?*Type {
    const u = v.asUserdata() orelse return null;
    if (!std.mem.eql(u8, u.tname, type_tname)) return null;
    return u.as(*Type).*;
}

pub fn argType(th: *Thread, args: []Value, i: usize, name: []const u8) Error!*Type {
    return (try api.argUserdata(th, args, i, name, *Type, type_tname)).*;
}

fn optType(th: *Thread, args: []Value, i: usize, name: []const u8) Error!?*Type {
    if (api.arg(args, i) == .null) return null;
    return try argType(th, args, i, name);
}

fn scalar(kind: Kind, name: []const u8, size: usize, ffi: *FfiType) Type {
    return .{ .kind = kind, .size = size, .alignment = size, .name = name, .ffi = ffi };
}

/// The primitive type of a name, made once.
pub fn primitive(name: []const u8) ?*Type {
    const S = struct {
        var void_t = Type{ .kind = .void, .size = 0, .alignment = 1, .name = "void", .ffi = &d_void };
        var bool_t = scalar(.bool, "bool", 1, &d_u8);
        var char_t = blk: {
            var c = scalar(.i8, "char", 1, &d_i8);
            c.char = true;
            break :blk c;
        };
        var i8_t = scalar(.i8, "int8", 1, &d_i8);
        var u8_t = scalar(.u8, "uint8", 1, &d_u8);
        var i16_t = scalar(.i16, "int16", 2, &d_i16);
        var u16_t = scalar(.u16, "uint16", 2, &d_u16);
        var i32_t = scalar(.i32, "int32", 4, &d_i32);
        var u32_t = scalar(.u32, "uint32", 4, &d_u32);
        var i64_t = scalar(.i64, "int64", 8, &d_i64);
        var u64_t = scalar(.u64, "uint64", 8, &d_u64);
        var f32_t = scalar(.f32, "float", 4, &d_f32);
        var f64_t = scalar(.f64, "double", 8, &d_f64);
        var ptr_t = scalar(.pointer, "void *", @sizeOf(usize), &d_ptr);
        var str_t = scalar(.string, "const char *", @sizeOf(usize), &d_ptr);
    };
    const P = struct { n: []const u8, t: *Type };
    const all = [_]P{
        .{ .n = "void", .t = &S.void_t },     .{ .n = "bool", .t = &S.bool_t },
        .{ .n = "char", .t = &S.char_t },     .{ .n = "int8", .t = &S.i8_t },
        .{ .n = "uint8", .t = &S.u8_t },      .{ .n = "int16", .t = &S.i16_t },
        .{ .n = "uint16", .t = &S.u16_t },    .{ .n = "int32", .t = &S.i32_t },
        .{ .n = "uint32", .t = &S.u32_t },    .{ .n = "int64", .t = &S.i64_t },
        .{ .n = "uint64", .t = &S.u64_t },    .{ .n = "float", .t = &S.f32_t },
        .{ .n = "double", .t = &S.f64_t },    .{ .n = "pointer", .t = &S.ptr_t },
        .{ .n = "string", .t = &S.str_t },
    };
    for (all) |p| {
        if (std.mem.eql(u8, p.n, name)) return p.t;
    }
    return null;
}

/// The name of a scalar type as primitive() takes it, NUL terminated, or
/// null for other types.
pub fn primitiveName(t: *const Type) ?[*:0]const u8 {
    if (t.char) return "char";
    return switch (t.kind) {
        .bool => "bool",
        .i8 => "int8",
        .u8 => "uint8",
        .i16 => "int16",
        .u16 => "uint16",
        .i32 => "int32",
        .u32 => "uint32",
        .i64 => "int64",
        .u64 => "uint64",
        .f32 => "float",
        .f64 => "double",
        else => null,
    };
}

/// primitive(name) -> the type: void, bool, char (an int8 whose arrays are
/// strings), int8..int64, uint8..uint64, float, double, pointer (void *)
/// or string (const char *)
fn ctPrimitive(th: *Thread, args: []Value) Error!Value {
    const name = try api.argString(th, args, 0, "name");
    const t = primitive(name) orelse return th.vm.raise("ffi: unknown primitive type {s}", .{name});
    return typeValue(th.vm, t);
}

/// pointer(target) -> the type of a pointer to target (null: void *)
fn ctPointer(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const target = try optType(th, args, 0, "target");
    var t = scalar(.pointer, "void *", @sizeOf(usize), &d_ptr);
    t.elem = target;
    if (target) |tt| t.name = std.fmt.allocPrint(vm.gpa, "{s} *", .{tt.name}) catch oom();
    return typeValue(vm, newType(vm, t));
}

/// function(ret, {args...}) -> the type of a pointer to a C function with
/// that signature: a slang function given for it becomes a callback
fn ctFunction(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const ret = try argType(th, args, 0, "ret");
    const list = try api.argTable(th, args, 1, "args");
    const n = list.arrayLen();
    const types = vm.gpa.alloc(*Type, n) catch oom();
    for (0..n) |i| {
        const a = asType(list.getInt(@intCast(i))) orelse return vm.raise("ffi: argument {d} of a function type has no type", .{i});
        if (!a.complete or a.kind == .void or a.kind == .array) return vm.raise("ffi: a callback cannot take a {s}", .{a.name});
        types[i] = a;
    }
    if (!ret.complete or ret.kind == .array) return vm.raise("ffi: a callback cannot return a {s}", .{ret.name});
    const sig = vm.gpa.create(Signature) catch oom();
    sig.* = .{ .ret = ret, .args = types };
    var t = scalar(.function, "function", @sizeOf(usize), &d_ptr);
    t.sig = sig;
    t.name = std.fmt.allocPrint(vm.gpa, "{s} (*)()", .{ret.name}) catch oom();
    return typeValue(vm, newType(vm, t));
}

/// array(elem, n) -> the type of n elems in a row (a struct field)
fn ctArray(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const elem = try argType(th, args, 0, "elem");
    const n: usize = @intCast(@max(0, try api.argInt(th, args, 1, "n")));
    // libffi has no arrays: a struct of n elements has the same layout
    const els = vm.gpa.alloc(?*FfiType, n + 1) catch oom();
    for (0..n) |i| els[i] = elem.ffi;
    els[n] = null;
    const f = vm.gpa.create(FfiType) catch oom();
    f.* = .{ .size = 0, .alignment = 0, .type = T_STRUCT, .elements = els.ptr };
    return typeValue(vm, newType(vm, .{
        .kind = .array,
        .size = elem.size * n,
        .alignment = elem.alignment,
        .name = std.fmt.allocPrint(vm.gpa, "{s}[{d}]", .{ elem.name, n }) catch oom(),
        .ffi = f,
        .elem = elem,
        .count = n,
    }));
}

/// tbl[key] for a struct field: a small record holds interned keys, so a
/// scan comparing pointers finds it without hashing.
inline fn fieldOf(tbl: *const Table, key: *String) Value {
    if (!tbl.indexed) {
        for (tbl.ents.items) |e| {
            if (e.key == .string and e.key.string == key) return e.val;
        }
    }
    return tbl.getStr(key);
}

/// The interned string for a field name, kept alive in the registry (a
/// Type is never freed, so neither are its keys).
fn pinKey(vm: *VM, name: []const u8) *String {
    const s = vm.newString(name);
    const pins = vm.registry.getName("ctypes_keys").asTable() orelse blk: {
        const t = vm.newTable(0, 16);
        vm.registry.set(vm.gpa, vm.str("ctypes_keys"), .{ .table = t });
        break :blk t;
    };
    pins.set(vm.gpa, .{ .string = s }, .{ .bool = true });
    return s;
}

/// struct(name) -> a struct type to be defined with define (an opaque
/// struct until then: pointers to it work, values do not)
fn ctStruct(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const name = try api.argString(th, args, 0, "name");
    const f = vm.gpa.create(FfiType) catch oom();
    f.* = .{ .size = 0, .alignment = 0, .type = T_STRUCT, .elements = null };
    return typeValue(vm, newType(vm, .{
        .kind = .@"struct",
        .size = 0,
        .alignment = 1,
        .name = vm.gpa.dupe(u8, name) catch oom(),
        .ffi = f,
        .complete = false,
    }));
}

/// define(struct_type, {{name, type, [default]}, ...}): the fields, laid
/// out by C's rules (each at its alignment, the size rounded to the
/// largest); default (a number or bool) is used when a table leaves the
/// field out
fn ctDefine(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try argType(th, args, 0, "struct");
    const list = try api.argTable(th, args, 1, "fields");
    if (t.kind != .@"struct") return vm.raise("ffi.define: {s} is not a struct", .{t.name});
    const n = list.arrayLen();
    const fields = vm.gpa.alloc(Field, n) catch oom();
    const els = vm.gpa.alloc(?*FfiType, n + 1) catch oom();
    var offset: usize = 0;
    var alignment: usize = 1;
    for (0..n) |i| {
        const pair = list.getInt(@intCast(i)).asTable() orelse return vm.raise("ffi.define: field {d} must be {{name, type}}", .{i});
        const fname = pair.getInt(0).asBytes() orelse return vm.raise("ffi.define: field {d} has no name", .{i});
        const ft = asType(pair.getInt(1)) orelse return vm.raise("ffi.define: field {s} has no type", .{fname});
        if (!ft.complete or ft.kind == .void) return vm.raise("ffi.define: field {s} of {s} has the incomplete type {s}", .{ fname, t.name, ft.name });
        // (a struct result is filled without lookups, which needs the
        // names to be distinct)
        for (fields[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, fname)) return vm.raise("ffi.define: {s} has two fields named {s}", .{ t.name, fname });
        }
        offset = std.mem.alignForward(usize, offset, ft.alignment);
        const def = pair.getInt(2);
        fields[i] = .{
            .name = vm.gpa.dupe(u8, fname) catch oom(),
            .key = pinKey(vm, fname),
            .offset = offset,
            .ty = ft,
            .default = switch (def) {
                .int, .float, .bool => def,
                else => null,
            },
        };
        els[i] = ft.ffi;
        offset += ft.size;
        alignment = @max(alignment, ft.alignment);
    }
    els[n] = null;
    t.fields = fields;
    t.alignment = alignment;
    t.size = std.mem.alignForward(usize, offset, alignment);
    t.ffi.elements = els.ptr;
    t.complete = true;
    return .null;
}

fn ctSizeof(th: *Thread, args: []Value) Error!Value {
    const t = try argType(th, args, 0, "type");
    return .{ .int = @intCast(t.size) };
}

fn findField(t: *Type, name: []const u8) ?*Field {
    for (t.fields) |*f| {
        if (std.mem.eql(u8, f.name, name)) return f;
    }
    return null;
}

fn ctOffsetof(th: *Thread, args: []Value) Error!Value {
    const t = try argType(th, args, 0, "type");
    const name = try api.argString(th, args, 1, "field");
    const f = findField(t, name) orelse return th.vm.raise("ffi: {s} has no field {s}", .{ t.name, name });
    return .{ .int = @intCast(f.offset) };
}

fn ctTypeName(th: *Thread, args: []Value) Error!Value {
    const t = try argType(th, args, 0, "type");
    return th.vm.str(t.name);
}

// ------------------------------------------------------------ pointers

pub fn newPointer(vm: *VM, addr: usize, ty: ?*Type, owner: Value) Value {
    if (addr == 0) return .null;
    const u = vm.newUserdataOf(Ptr, .{ .addr = addr, .ty = ty }, pointer_tname, vm.lib.pointer_meta);
    u.owner = owner;
    u.kind = .pointer;
    u.to_string = ptrToString;
    return .{ .userdata = u };
}

fn ptrToString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const p = u.as(Ptr);
    const name = if (p.ty) |t| t.name else "void";
    try w.print("ffi.pointer<{s}>: 0x{x}", .{ name, p.addr });
}

/// A pointer or a buffer: memory with an address.
pub fn asMemory(v: Value) ?*Userdata {
    const u = v.asUserdata() orelse return null;
    if (u.kind == .plain) return null;
    return u;
}

pub fn asPointer(v: Value) ?*Userdata {
    const u = v.asUserdata() orelse return null;
    if (u.kind != .pointer) return null;
    return u;
}

/// What keeps the memory of a pointer or buffer alive: itself when it owns
/// its memory or ffi.gc frees it (so a view never outlives what it sees),
/// else its owner.
fn ownerOf(u: *Userdata) Value {
    // a pointer ffi.gc frees stays alive while anything made from it is
    if (u.finalizer == freePointer) return .{ .userdata = u };
    if (u.owner != .null) return u.owner;
    if (u.data.len > @sizeOf(Ptr)) return .{ .userdata = u };
    return .null;
}

fn argMemory(th: *Thread, args: []Value, i: usize, name: []const u8) Error!*Userdata {
    const v = api.arg(args, i);
    return asMemory(v) orelse return api.argError(th, name, i, pointer_tname, v);
}

/// new(type, [n]) -> a pointer to n (1 by default) zeroed values of type,
/// memory the collector frees when nothing points into it
fn ctNew(th: *Thread, args: []Value) Error!Value {
    const t = try argType(th, args, 0, "type");
    const n: usize = @intCast(@max(1, api.argIntOr(args, 1, 1)));
    const u = try ownedMemory(th, t, n, .pointer);
    return .{ .userdata = u };
}

/// A new buffer of n zeroed values of type t (for slang.h).
pub fn newBuffer(th: *Thread, t: *Type, n: usize) Error!*Userdata {
    return ownedMemory(th, t, n, .buffer);
}

/// Zeroed memory for n values of type t inside a new userdata.
fn ownedMemory(th: *Thread, t: *Type, n: usize, kind: vm_mod.UserKind) Error!*Userdata {
    const vm = th.vm;
    if (!t.complete or t.size == 0) return vm.raise("{s} has no size", .{t.name});
    const bytes = std.math.mul(usize, t.size, n) catch return vm.raise("{d} values of {s} do not fit in memory", .{ n, t.name });
    const tname = if (kind == .buffer) buffer_tname else pointer_tname;
    const meta = if (kind == .buffer) vm.lib.buffer_meta else vm.lib.pointer_meta;
    const u = vm.newUserdata(@sizeOf(Ptr) + bytes + 16, tname, meta);
    const base = @intFromPtr(u.data.ptr) + @sizeOf(Ptr);
    u.as(Ptr).* = .{ .addr = std.mem.alignForward(usize, base, @max(t.alignment, 1)), .ty = t, .count = n };
    u.kind = kind;
    u.to_string = if (kind == .buffer) bufToStringFn else ptrToString;
    return u;
}

/// cast(pointer, type) -> the same address as a pointer to type (null:
/// void *); an int is taken as an address
fn ctCast(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try optType(th, args, 1, "type");
    const v = api.arg(args, 0);
    if (v == .int) return newPointer(vm, @intCast(v.int), t, .null);
    const u = try argMemory(th, args, 0, "pointer");
    return newPointer(vm, u.as(Ptr).addr, t, ownerOf(u));
}

/// offset(pointer, n) -> the pointer n elements further
fn ctOffset(th: *Thread, args: []Value) Error!Value {
    const u = try argMemory(th, args, 0, "pointer");
    const n = try api.argInt(th, args, 1, "n");
    const p = u.as(Ptr);
    const size: i64 = if (p.ty) |t| @intCast(t.size) else 1;
    const addr: i64 = @as(i64, @intCast(p.addr)) + n * size;
    return newPointer(th.vm, @intCast(addr), p.ty, ownerOf(u));
}

fn ctAddress(th: *Thread, args: []Value) Error!Value {
    if (api.arg(args, 0) == .null) return .{ .int = 0 };
    const u = try argMemory(th, args, 0, "pointer");
    return .{ .int = @intCast(u.as(Ptr).addr) };
}

/// string(pointer, [len]) -> the C string at pointer, or len bytes
fn ctString(th: *Thread, args: []Value) Error!Value {
    if (api.arg(args, 0) == .null) return .null;
    const u = try argMemory(th, args, 0, "pointer");
    const base: [*]const u8 = @ptrFromInt(u.as(Ptr).addr);
    if (api.arg(args, 1) != .null) {
        const n = try api.argInt(th, args, 1, "len");
        return th.vm.str(base[0..@intCast(@max(0, n))]);
    }
    return th.vm.str(std.mem.span(@as([*:0]const u8, @ptrCast(base))));
}

/// value(pointer) -> the value it points to, as a slang value (a struct is
/// copied into a table)
fn ctValue(th: *Thread, args: []Value) Error!Value {
    const u = try argMemory(th, args, 0, "pointer");
    const p = u.as(Ptr);
    const t = p.ty orelse return th.vm.raise("ffi.value: a void pointer has no value", .{});
    return fromC(th.vm, t, @ptrFromInt(p.addr), .null);
}

/// The element or field memory is indexed with: its address and type.
const Place = struct { addr: usize, ty: *Type };

fn place(th: *Thread, u: *Userdata, key: Value) Error!?Place {
    const p = u.as(Ptr);
    const t = p.ty orelse return th.vm.raise("ffi: cannot index a void pointer", .{});
    switch (key) {
        .int => |i| {
            if (!t.complete or t.size == 0) return th.vm.raise("ffi: cannot index a pointer to {s}", .{t.name});
            if (u.kind == .buffer and (i < 0 or i >= p.count)) {
                return th.vm.raise("buffer index {d} out of range (length {d})", .{ i, p.count });
            }
            const addr: i64 = @as(i64, @intCast(p.addr)) + i * @as(i64, @intCast(t.size));
            return .{ .addr = @intCast(addr), .ty = t };
        },
        .string => |s| {
            if (u.kind == .buffer or t.kind != .@"struct") return null;
            const f = findField(t, s.bytes()) orelse return null;
            return .{ .addr = p.addr + f.offset, .ty = f.ty };
        },
        else => return null,
    }
}

/// The value at a place: a scalar is read; a struct (or an array) is a
/// pointer to it, so it can be read and written further.
fn readPlace(vm: *VM, u: *Userdata, pl: Place) Value {
    return switch (pl.ty.kind) {
        .@"struct" => newPointer(vm, pl.addr, pl.ty, ownerOf(u)),
        .array => if (pl.ty.elem.?.char)
            fromC(vm, pl.ty, @ptrFromInt(pl.addr), .null)
        else
            newPointer(vm, pl.addr, pl.ty.elem, ownerOf(u)),
        else => fromC(vm, pl.ty, @ptrFromInt(pl.addr), .null),
    };
}

/// p[i], p.field
fn ptrIndex(th: *Thread, args: []Value) Error!Value {
    const u = asMemory(api.arg(args, 0)) orelse return .null;
    const pl = (try place(th, u, api.arg(args, 1))) orelse return .null;
    return readPlace(th.vm, u, pl);
}

fn ptrNewIndex(th: *Thread, args: []Value) Error!Value {
    const u = asMemory(api.arg(args, 0)) orelse return .null;
    const key = api.arg(args, 1);
    const pl = (try place(th, u, key)) orelse {
        const k = key.asBytes() orelse "?";
        return th.vm.raise("ffi: {s} has no field {s}", .{ if (u.as(Ptr).ty) |t| t.name else "void", k });
    };
    var conv = Conv{ .th = th };
    try conv.toC(api.arg(args, 2), pl.ty, @ptrFromInt(pl.addr), false);
    return .null;
}

fn ptrEq(th: *Thread, args: []Value) Error!Value {
    _ = th;
    const a = asMemory(api.arg(args, 0)) orelse return .{ .bool = false };
    const b = asMemory(api.arg(args, 1)) orelse return .{ .bool = false };
    return .{ .bool = a.as(Ptr).addr == b.as(Ptr).addr };
}

// ------------------------------------------------------------ buffers

fn newBufferView(vm: *VM, addr: usize, ty: *Type, count: usize, owner: Value) *Userdata {
    const u = vm.newUserdataOf(Ptr, .{ .addr = addr, .ty = ty, .count = count }, buffer_tname, vm.lib.buffer_meta);
    u.owner = owner;
    u.kind = .buffer;
    u.to_string = bufToStringFn;
    return u;
}

fn bufToStringFn(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const p = u.as(Ptr);
    try w.print("buffer<{s}>[{d}]", .{ p.ty.?.name, p.count });
}

pub fn asBuffer(v: Value) ?*Userdata {
    const u = v.asUserdata() orelse return null;
    if (u.kind != .buffer) return null;
    return u;
}

fn argBuffer(th: *Thread, args: []Value, i: usize, name: []const u8) Error!*Userdata {
    const v = api.arg(args, i);
    return asBuffer(v) orelse return api.argError(th, name, i, buffer_tname, v);
}

fn bytesOf(u: *Userdata) []u8 {
    const p = u.as(Ptr);
    const base: [*]u8 = @ptrFromInt(p.addr);
    return base[0 .. p.count * p.ty.?.size];
}

/// buffer(type, n) -> n zeroed elements of type
fn ctBuffer(th: *Thread, args: []Value) Error!Value {
    const t = try argType(th, args, 0, "type");
    const n = try api.argInt(th, args, 1, "n");
    if (n < 0) return th.vm.raise("buffer: a negative length {d}", .{n});
    if (t.kind == .void) return th.vm.raise("buffer: void has no size", .{});
    return .{ .userdata = try ownedMemory(th, t, @intCast(n), .buffer) };
}

/// buffer_from(type, list or string) -> a buffer with the list's elements,
/// or the string's bytes (for a type of size 1, or any type when the
/// string's length is a multiple of its size)
fn ctBufferFrom(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try argType(th, args, 0, "type");
    const src = api.arg(args, 1);
    if (src.asBytes()) |s| {
        if (t.size == 0 or s.len % t.size != 0) return vm.raise("buffer.from: {d} bytes are not a whole number of {s}", .{ s.len, t.name });
        const u = try ownedMemory(th, t, s.len / t.size, .buffer);
        @memcpy(bytesOf(u), s);
        return .{ .userdata = u };
    }
    const list = src.asTable() orelse return api.argError(th, "list", 1, "list or string", src);
    const n = list.arrayLen();
    const u = try ownedMemory(th, t, n, .buffer);
    var conv = Conv{ .th = th, .label = "buffer.from" };
    const base: [*]u8 = @ptrFromInt(u.as(Ptr).addr);
    for (0..n) |i| try conv.toC(list.getInt(@intCast(i)), t, base + i * t.size, false);
    return .{ .userdata = u };
}

/// wrap(pointer, n, [type]) -> a buffer over n elements of C memory at
/// pointer (of its type, or type); the memory stays C's
fn ctWrap(th: *Thread, args: []Value) Error!Value {
    const u = try argMemory(th, args, 0, "pointer");
    const n = try api.argInt(th, args, 1, "n");
    const t = (try optType(th, args, 2, "type")) orelse u.as(Ptr).ty orelse return th.vm.raise("buffer.wrap: a void pointer needs a type", .{});
    if (n < 0) return th.vm.raise("buffer.wrap: a negative length {d}", .{n});
    return .{ .userdata = newBufferView(th.vm, u.as(Ptr).addr, t, @intCast(n), ownerOf(u)) };
}

fn ctIsBuffer(th: *Thread, args: []Value) Error!Value {
    _ = th;
    return .{ .bool = asBuffer(api.arg(args, 0)) != null };
}

fn bufIndex(th: *Thread, args: []Value) Error!Value {
    const u = asBuffer(api.arg(args, 0)) orelse return .null;
    const key = api.arg(args, 1);
    if (key == .string) {
        // the properties: size (in bytes), type, shared
        const name = key.string.bytes();
        if (std.mem.eql(u8, name, "size")) return bufSize(th, args[0..1]);
        if (std.mem.eql(u8, name, "type")) return bufType(th, args[0..1]);
        if (std.mem.eql(u8, name, "shared")) return bufIsShared(th, args[0..1]);
        return th.vm.lib.buffer_methods.?.get(key);
    }
    const pl = (try place(th, u, key)) orelse return .null;
    return readPlace(th.vm, u, pl);
}

fn bufNewIndex(th: *Thread, args: []Value) Error!Value {
    const u = asBuffer(api.arg(args, 0)) orelse return .null;
    const key = api.arg(args, 1);
    if (key != .int) return th.vm.raise("a buffer is indexed with ints, not {s}", .{key.typeName()});
    const pl = (try place(th, u, key)).?;
    var conv = Conv{ .th = th };
    try conv.toC(api.arg(args, 2), pl.ty, @ptrFromInt(pl.addr), false);
    return .null;
}

fn bufLen(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    return .{ .int = @intCast(u.as(Ptr).count) };
}

/// == on buffers: the same element type and the same bytes
fn bufEq(th: *Thread, args: []Value) Error!Value {
    _ = th;
    const a = asBuffer(api.arg(args, 0)) orelse return .{ .bool = false };
    const b = asBuffer(api.arg(args, 1)) orelse return .{ .bool = false };
    const pa = a.as(Ptr);
    const pb = b.as(Ptr);
    if (pa.count != pb.count or !sameType(pa.ty.?, pb.ty.?)) return .{ .bool = false };
    return .{ .bool = std.mem.eql(u8, bytesOf(a), bytesOf(b)) };
}

fn bufSize(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    return .{ .int = @intCast(bytesOf(u).len) };
}

fn bufType(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    return typeValue(th.vm, u.as(Ptr).ty.?);
}

/// b:slice(from, [to]) -> the elements from .. to - 1, sharing the memory
fn bufSlice(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const p = u.as(Ptr);
    const count: i64 = @intCast(p.count);
    const from = api.argIntOr(args, 1, 0);
    const to = if (api.arg(args, 2) == .null) count else try api.argInt(th, args, 2, "to");
    if (from < 0 or to < from or to > count) return th.vm.raise("buffer:slice({d}, {d}) out of range (length {d})", .{ from, to, count });
    const t = p.ty.?;
    return .{ .userdata = newBufferView(th.vm, p.addr + @as(usize, @intCast(from)) * t.size, t, @intCast(to - from), ownerOf(u)) };
}

/// b:copy() -> a new buffer with the same elements
fn bufCopy(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const p = u.as(Ptr);
    const c = try ownedMemory(th, p.ty.?, p.count, .buffer);
    @memcpy(bytesOf(c), bytesOf(u));
    return .{ .userdata = c };
}

/// b:fill(v) -> b, every element set to v
fn bufFill(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const p = u.as(Ptr);
    const t = p.ty.?;
    if (p.count == 0) return args[0];
    var conv = Conv{ .th = th, .label = "buffer:fill" };
    const base: [*]u8 = @ptrFromInt(p.addr);
    try conv.toC(api.arg(args, 1), t, base, false);
    // the first element, copied over the rest
    var i: usize = 1;
    while (i < p.count) : (i += 1) @memcpy(base[i * t.size ..][0..t.size], base[0..t.size]);
    return args[0];
}

/// b:set(list or buffer, [at]) -> b, the elements written from index at
/// (0 by default)
fn bufSet(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const p = u.as(Ptr);
    const t = p.ty.?;
    const at = api.argIntOr(args, 2, 0);
    const src = api.arg(args, 1);
    const base: [*]u8 = @ptrFromInt(p.addr);
    if (asBuffer(src)) |s| {
        const sp = s.as(Ptr);
        if (!sameType(sp.ty.?, t)) return th.vm.raise("buffer:set: a buffer of {s} into a buffer of {s}", .{ sp.ty.?.name, t.name });
        if (at < 0 or at + @as(i64, @intCast(sp.count)) > p.count) return th.vm.raise("buffer:set: {d} elements at {d} do not fit (length {d})", .{ sp.count, at, p.count });
        // the memory may overlap (slices of one buffer)
        std.mem.copyForwards(u8, base[@as(usize, @intCast(at)) * t.size ..][0 .. sp.count * t.size], bytesOf(s));
        return args[0];
    }
    const list = src.asTable() orelse return api.argError(th, "list", 1, "list or buffer", src);
    const n = list.arrayLen();
    if (at < 0 or at + @as(i64, @intCast(n)) > p.count) return th.vm.raise("buffer:set: {d} elements at {d} do not fit (length {d})", .{ n, at, p.count });
    var conv = Conv{ .th = th, .label = "buffer:set" };
    for (0..n) |i| try conv.toC(list.getInt(@intCast(i)), t, base + (@as(usize, @intCast(at)) + i) * t.size, false);
    return args[0];
}

/// b:cast(type) -> the same bytes as elements of type (the length is the
/// bytes that fit whole elements)
fn bufCast(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const t = try argType(th, args, 1, "type");
    if (!t.complete or t.size == 0) return th.vm.raise("buffer:cast: {s} has no size", .{t.name});
    const bytes = bytesOf(u).len;
    return .{ .userdata = newBufferView(th.vm, u.as(Ptr).addr, t, bytes / t.size, ownerOf(u)) };
}

/// b:to_list() -> the elements as a list (structs as tables)
fn bufToList(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const p = u.as(Ptr);
    const t = p.ty.?;
    const out = th.vm.newTable(p.count, 0);
    const base: [*]const u8 = @ptrFromInt(p.addr);
    for (0..p.count) |i| out.append(th.vm.gpa, fromC(th.vm, t, base + i * t.size, .null));
    return .{ .table = out };
}

/// b:to_string() -> the bytes of the buffer
fn bufToString(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    return th.vm.str(bytesOf(u));
}

/// b:same(other) -> whether both are the same memory (address, length and
/// type)
fn bufSame(th: *Thread, args: []Value) Error!Value {
    const a = try argBuffer(th, args, 0, "buffer");
    const b = asBuffer(api.arg(args, 1)) orelse return .{ .bool = false };
    const pa = a.as(Ptr);
    const pb = b.as(Ptr);
    return .{ .bool = pa.addr == pb.addr and pa.count == pb.count and sameType(pa.ty.?, pb.ty.?) };
}

/// b:pointer() -> a pointer to the first element (keeping b alive)
fn bufPointer(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    const p = u.as(Ptr);
    return newPointer(th.vm, p.addr, p.ty, ownerOf(u));
}

// ------------------------------------------------------------ shared buffers

/// The memory of a shared buffer (slang/isolate): outside every heap,
/// reference counted by the buffers of every VM that holds it, with a mutex
/// for whoever needs more than single element accesses to be atomic.
pub const SharedMem = struct {
    refs: std.atomic.Value(u32) = .init(1),
    mutex: std.Io.Mutex = .init,
    /// the OS thread holding the mutex (0: none), so that unlock can check
    owner: std.atomic.Value(std.Thread.Id) = .init(0),
    ty: *Type,
    count: usize,
    bytes: []align(16) u8,

    pub fn retain(m: *SharedMem) void {
        _ = m.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(m: *SharedMem) void {
        if (m.refs.fetchSub(1, .acq_rel) != 1) return;
        std.heap.c_allocator.free(m.bytes);
        std.heap.c_allocator.destroy(m);
    }
};

/// A shared buffer's userdata is {Ptr, *SharedMem}; slices of it keep it
/// alive through their owner.
fn sharedFinalize(data: ?*anyopaque) callconv(.c) void {
    const base: [*]u8 = @ptrCast(data.?);
    const m: **SharedMem = @ptrCast(@alignCast(base + @sizeOf(Ptr)));
    m.*.release();
}

/// The shared memory behind a buffer (itself or the buffer it slices), or
/// null for a buffer of one heap.
pub fn sharedOf(u: *Userdata) ?*SharedMem {
    const root = if (u.finalizer == sharedFinalize) u else (u.owner.asUserdata() orelse return null);
    if (root.finalizer != sharedFinalize) return null;
    const base: [*]u8 = root.data.ptr;
    return @as(**SharedMem, @ptrCast(@alignCast(base + @sizeOf(Ptr)))).*;
}

/// A buffer of vm over the whole of m, holding a reference of its own.
pub fn sharedBuffer(vm: *VM, m: *SharedMem) *Userdata {
    m.retain();
    const u = vm.newUserdata(@sizeOf(Ptr) + @sizeOf(*SharedMem), buffer_tname, vm.lib.buffer_meta);
    u.as(Ptr).* = .{ .addr = @intFromPtr(m.bytes.ptr), .ty = m.ty, .count = m.count };
    const base: [*]u8 = u.data.ptr;
    @as(**SharedMem, @ptrCast(@alignCast(base + @sizeOf(Ptr)))).* = m;
    u.finalizer = sharedFinalize;
    u.owner = .{ .userdata = u };
    u.kind = .buffer;
    u.to_string = bufToStringFn;
    return u;
}

/// A view of count elements of type ty at addr inside the shared buffer
/// root (a slice or cast that crossed to another isolate).
pub fn sharedView(vm: *VM, root: *Userdata, addr: usize, ty: *Type, count: usize) *Userdata {
    return newBufferView(vm, addr, ty, count, .{ .userdata = root });
}

/// shared_buffer(type, n) -> n zeroed elements of a scalar type in memory
/// that isolates share (it crosses channels by reference)
fn ctSharedBuffer(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try argType(th, args, 0, "type");
    const n = try api.argInt(th, args, 1, "n");
    if (n < 0) return vm.raise("buffer.shared: a negative length {d}", .{n});
    const name = primitiveName(t) orelse return vm.raise("buffer.shared: {s} is not a number type (shared buffers hold numbers)", .{t.name});
    const ty = primitive(std.mem.span(name)).?;
    const bytes = std.math.mul(usize, ty.size, @intCast(n)) catch return vm.raise("{d} values of {s} do not fit in memory", .{ n, ty.name });
    const mem = std.heap.c_allocator.alignedAlloc(u8, .@"16", @max(bytes, 1)) catch oom();
    @memset(mem, 0);
    const m = std.heap.c_allocator.create(SharedMem) catch oom();
    m.* = .{ .ty = ty, .count = @intCast(n), .bytes = mem };
    const u = sharedBuffer(vm, m);
    m.release();
    return .{ .userdata = u };
}

/// b:is_shared() -> whether b's memory is shared between isolates
fn bufIsShared(th: *Thread, args: []Value) Error!Value {
    const u = try argBuffer(th, args, 0, "buffer");
    return .{ .bool = sharedOf(u) != null };
}

fn argShared(th: *Thread, args: []Value, what: []const u8) Error!*SharedMem {
    const u = try argBuffer(th, args, 0, "buffer");
    return sharedOf(u) orelse th.vm.raise("buffer:{s}: not a shared buffer (buffer.shared)", .{what});
}

fn lockShared(vm: *VM, m: *SharedMem) Error!void {
    const self = std.Thread.getCurrentId();
    if (m.owner.load(.acquire) == self) return vm.raise("buffer:lock: this isolate holds the lock already", .{});
    m.mutex.lockUncancelable(vm.io);
    m.owner.store(self, .release);
}

fn unlockShared(vm: *VM, m: *SharedMem) void {
    m.owner.store(0, .release);
    m.mutex.unlock(vm.io);
}

/// b:lock(f?) -> any: with f, holds b's mutex while f() runs and returns
/// its result (released also when f raises); without, takes the mutex
/// until b:unlock()
fn bufLock(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const m = try argShared(th, args, "lock");
    const f = api.arg(args, 1);
    if (f != .null and f != .function) return api.argError(th, "f", 1, "Closure", f);
    try lockShared(vm, m);
    if (f == .null) return .null;
    defer unlockShared(vm, m);
    return th.call(f, &.{});
}

/// b:unlock(): releases the mutex taken by b:lock()
fn bufUnlock(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const m = try argShared(th, args, "unlock");
    if (m.owner.load(.acquire) != std.Thread.getCurrentId()) return vm.raise("buffer:unlock: the lock is not held here", .{});
    unlockShared(vm, m);
    return .null;
}

/// v as a C integer: ints as they are, floats truncated (clamped, nan as
/// 0), bools as 0 or 1; null for anything else.
pub inline fn intOf(v: Value) ?i64 {
    return switch (v) {
        .int => |i| i,
        .float => |f| if (std.math.isFinite(f)) @intFromFloat(std.math.clamp(f, -9.2e18, 9.2e18)) else 0,
        .bool => |b| @intFromBool(b),
        else => null,
    };
}

/// v as a C floating point number: null for anything but a number or bool.
pub inline fn numOf(v: Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .bool => |b| if (b) 1 else 0,
        else => null,
    };
}

/// The scalar of type t at src (t.isScalar() holds).
pub inline fn scalarGet(t: *const Type, src: [*]const u8) Value {
    return switch (t.kind) {
        .bool => .{ .bool = src[0] != 0 },
        .i8 => .{ .int = load(i8, src) },
        .u8 => .{ .int = load(u8, src) },
        .i16 => .{ .int = load(i16, src) },
        .u16 => .{ .int = load(u16, src) },
        .i32 => .{ .int = load(i32, src) },
        .u32 => .{ .int = load(u32, src) },
        .i64 => .{ .int = load(i64, src) },
        .u64 => .{ .int = @bitCast(load(u64, src)) },
        .f32 => .{ .float = load(f32, src) },
        .f64 => .{ .float = load(f64, src) },
        else => unreachable,
    };
}

/// Stores v as the scalar type t at dst (t.isScalar() holds): false when
/// v is not a number (Conv.toC then raises the message).
pub inline fn scalarSet(t: *const Type, dst: [*]u8, v: Value) bool {
    switch (t.kind) {
        .bool => dst[0] = @intFromBool(v.truthy()),
        .f32 => store(f32, dst, @floatCast(numOf(v) orelse return false)),
        .f64 => store(f64, dst, numOf(v) orelse return false),
        else => {
            const i = intOf(v) orelse return false;
            switch (t.kind) {
                .i8 => store(i8, dst, @truncate(i)),
                .u8 => store(u8, dst, @truncate(@as(u64, @bitCast(i)))),
                .i16 => store(i16, dst, @truncate(i)),
                .u16 => store(u16, dst, @truncate(@as(u64, @bitCast(i)))),
                .i32 => store(i32, dst, @truncate(i)),
                .u32 => store(u32, dst, @truncate(@as(u64, @bitCast(i)))),
                .i64 => store(i64, dst, i),
                .u64 => store(u64, dst, @bitCast(i)),
                else => unreachable,
            }
        },
    }
    return true;
}

/// u[i] for the VM's get_table: the element when u is a buffer of scalars
/// and i is in range, else null (fastGet then raises or the metatable
/// answers).
pub inline fn bufferGet(u: *Userdata, i: i64) ?Value {
    if (u.kind != .buffer) return null;
    const p = u.as(Ptr);
    const t = p.ty.?;
    // a negative i wraps to a huge index (u64: wider than usize on wasm32)
    const idx: u64 = @bitCast(i);
    if (!t.isScalar() or idx >= p.count) return null;
    return scalarGet(t, @ptrFromInt(p.addr + @as(usize, @intCast(idx)) * t.size));
}

/// u[i] = v for the VM's set_table: false when it is not the fast case
/// (fastSet then raises or the metatable takes it).
pub inline fn bufferSet(u: *Userdata, i: i64, v: Value) bool {
    if (u.kind != .buffer) return false;
    const p = u.as(Ptr);
    const t = p.ty.?;
    const idx: u64 = @bitCast(i);
    if (!t.isScalar() or idx >= p.count) return false;
    return scalarSet(t, @ptrFromInt(p.addr + @as(usize, @intCast(idx)) * t.size), v);
}

fn indexError(th: *Thread, p: *const Ptr, i: i64) Error {
    return th.vm.raise("buffer index {d} out of range (length {d})", .{ i, p.count });
}

/// The slow path of bufferGet: the element, an error for an index out of
/// range, or null when the element type is not a scalar (the metatable
/// handles it then).
pub fn fastGet(th: *Thread, u: *Userdata, i: i64) Error!?Value {
    if (bufferGet(u, i)) |v| return v;
    const p = u.as(Ptr);
    if (!p.ty.?.isScalar()) return null;
    return indexError(th, p, i);
}

/// The slow path of bufferSet: stores, or raises for an index out of
/// range or a value that is not a number; false when the element type is
/// not a scalar.
pub fn fastSet(th: *Thread, u: *Userdata, i: i64, v: Value) Error!bool {
    if (bufferSet(u, i, v)) return true;
    const p = u.as(Ptr);
    const t = p.ty.?;
    if (!t.isScalar()) return false;
    if (i < 0 or i >= p.count) return indexError(th, p, i);
    var conv = Conv{ .th = th };
    try conv.toC(v, t, @ptrFromInt(p.addr + @as(usize, @intCast(i)) * t.size), false);
    return true;
}

/// The iterators of values(b), keys(b) and entries(b): the element at an
/// index, for core.zig.
pub fn element(th: *Thread, u: *Userdata, i: usize) Error!?Value {
    const p = u.as(Ptr);
    if (i >= p.count) return null;
    return readPlace(th.vm, u, (try place(th, u, .{ .int = @intCast(i) })).?);
}

pub fn countOf(u: *Userdata) usize {
    return u.as(Ptr).count;
}

// ------------------------------------------------------------ conversions

/// A table whose temporary C copy goes back into it after the call.
const Writeback = struct { table: *Table, ty: *Type, mem: [*]u8, list: bool, n: usize };

pub const Conv = struct {
    th: *Thread,
    /// temporary memory of a call; null when writing into C memory, where
    /// nothing temporary may be stored
    scratch: ?*Scratch = null,
    writebacks: std.ArrayList(Writeback) = .empty,
    /// what is being converted, for messages: argument `arg` (from 1) of
    /// the function `fname` when arg is set, else the label
    label: []const u8 = "ffi: cannot store the value",
    fname: []const u8 = "",
    arg: usize = 0,
    msg_buf: [128]u8 = undefined,

    /// The message prefix (formatted only when a conversion fails).
    fn what(c: *Conv) []const u8 {
        if (c.arg == 0) return c.label;
        return std.fmt.bufPrint(&c.msg_buf, "bad argument #{d} to '{s}'", .{ c.arg, c.fname }) catch "bad argument";
    }

    fn fail(c: *Conv, t: *Type, v: Value) Error {
        return c.th.vm.raise("{s} ({s} expected, got {s})", .{ c.what(), t.name, v.typeName() });
    }

    fn number(c: *Conv, t: *Type, v: Value) Error!f64 {
        return numOf(v) orelse c.fail(t, v);
    }

    fn integer(c: *Conv, t: *Type, v: Value) Error!i64 {
        return intOf(v) orelse c.fail(t, v);
    }

    fn temp(c: *Conv, t: *Type, n: usize, v: Value) Error![*]u8 {
        const s = c.scratch orelse return c.th.vm.raise("{s} (a {s} cannot be stored in C memory: use ffi.new)", .{ c.what(), v.typeName() });
        const size = @max(t.size * n, 1);
        const mem = s.bytes(c.th.vm.gpa, size);
        @memset(mem[0..size], 0);
        return mem;
    }

    /// v as a value of type t at dst. writeback: a table given for a
    /// pointer is copied back after the call.
    pub fn toC(c: *Conv, v: Value, t: *Type, dst: [*]u8, writeback: bool) Error!void {
        switch (t.kind) {
            .void => {},
            .bool => dst[0] = @intFromBool(v.truthy()),
            .i8 => store(i8, dst, @truncate(try c.integer(t, v))),
            .u8 => store(u8, dst, @truncate(@as(u64, @bitCast(try c.integer(t, v))))),
            .i16 => store(i16, dst, @truncate(try c.integer(t, v))),
            .u16 => store(u16, dst, @truncate(@as(u64, @bitCast(try c.integer(t, v))))),
            .i32 => store(i32, dst, @truncate(try c.integer(t, v))),
            .u32 => store(u32, dst, @truncate(@as(u64, @bitCast(try c.integer(t, v))))),
            .i64 => store(i64, dst, try c.integer(t, v)),
            .u64 => store(u64, dst, @bitCast(try c.integer(t, v))),
            .f32 => store(f32, dst, @floatCast(try c.number(t, v))),
            .f64 => store(f64, dst, try c.number(t, v)),
            .pointer, .string => store(usize, dst, try c.address(v, t, writeback)),
            .@"struct" => try c.structToC(v, t, dst),
            .array => try c.arrayToC(v, t, dst),
            .function => store(usize, dst, try c.function(v, t)),
        }
    }

    /// a function pointer: null, a pointer (to a C function), or a slang
    /// function, which becomes a callback
    fn function(c: *Conv, v: Value, t: *Type) Error!usize {
        switch (v) {
            .null => return 0,
            .function => {
                const make = make_callback orelse return c.th.vm.raise("{s} (this slang has no libffi: a slang function cannot be a C callback)", .{c.what()});
                return make(c.th, v, t);
            },
            .userdata => |u| {
                if (u.kind == .pointer) return u.as(Ptr).addr;
                return c.fail(t, v);
            },
            else => return c.fail(t, v),
        }
    }

    fn address(c: *Conv, v: Value, t: *Type, writeback: bool) Error!usize {
        switch (v) {
            .null => return 0,
            .userdata => |u| {
                if (u.kind == .pointer) return u.as(Ptr).addr;
                if (u.kind == .buffer) {
                    // the buffer's memory: its elements must be what the
                    // pointer points to, unless it takes any bytes
                    const p = u.as(Ptr);
                    if (t.kind == .pointer and !t.takesBytes() and !sameType(t.elem.?, p.ty.?)) {
                        return c.th.vm.raise("{s} ({s} expected, got a buffer of {s}: use b:cast)", .{ c.what(), t.name, p.ty.?.name });
                    }
                    return p.addr;
                }
                return c.fail(t, v);
            },
            .string => |s| {
                // the bytes of the string (NUL terminated), during the call
                if (c.scratch == null) return c.th.vm.raise("{s} (a string cannot be stored in C memory: use ffi.new)", .{c.what()});
                return @intFromPtr(s.bytes().ptr);
            },
            .table => |tbl| {
                if (t.kind == .string) return c.fail(t, v);
                const elem = t.elem orelse return c.fail(t, v);
                if (!elem.complete or elem.size == 0) return c.fail(t, v);
                // a list of elements, or (for a struct) one struct: {x, y}
                // and {} are a Vector2, {{x, y}} a list of them
                const first = tbl.getInt(0);
                const list = elem.kind != .@"struct" or first.asTable() != null or asMemory(first) != null;
                const n = if (list) tbl.arrayLen() else 1;
                const mem = try c.temp(elem, @max(n, 1), v);
                if (list) {
                    for (0..n) |i| try c.toC(tbl.getInt(@intCast(i)), elem, mem + i * elem.size, false);
                } else {
                    try c.structToC(v, elem, mem);
                }
                if (writeback) c.writebacks.append(c.th.vm.gpa, .{ .table = tbl, .ty = elem, .mem = mem, .list = list, .n = n }) catch oom();
                return @intFromPtr(mem);
            },
            else => return c.fail(t, v),
        }
    }

    fn structToC(c: *Conv, v: Value, t: *Type, dst: [*]u8) Error!void {
        if (!t.complete) return c.th.vm.raise("{s} ({s} is an incomplete struct)", .{ c.what(), t.name });
        if (asMemory(v)) |u| {
            const p = u.as(Ptr);
            if (p.ty != t) return c.fail(t, v);
            @memcpy(dst[0..t.size], @as([*]const u8, @ptrFromInt(p.addr))[0..t.size]);
            return;
        }
        const tbl = v.asTable() orelse return c.fail(t, v);
        for (t.fields, 0..) |f, i| {
            var fv = fieldOf(tbl, f.key);
            if (fv == .null) fv = tbl.getInt(@intCast(i));
            if (fv == .null) fv = f.default orelse continue; // zero, like C's {0}
            try c.toC(fv, f.ty, dst + f.offset, false);
        }
    }

    fn arrayToC(c: *Conv, v: Value, t: *Type, dst: [*]u8) Error!void {
        const elem = t.elem.?;
        if (v.asBytes()) |s| {
            if (elem.size != 1) return c.fail(t, v);
            const n = @min(s.len, t.count -| 1);
            @memcpy(dst[0..n], s[0..n]);
            dst[n] = 0;
            return;
        }
        if (asBuffer(v)) |u| {
            const p = u.as(Ptr);
            if (!sameType(p.ty.?, elem)) return c.fail(t, v);
            const n = @min(p.count, t.count) * elem.size;
            @memcpy(dst[0..n], bytesOf(u)[0..n]);
            return;
        }
        const tbl = v.asTable() orelse return c.fail(t, v);
        for (0..@min(tbl.arrayLen(), t.count)) |i| try c.toC(tbl.getInt(@intCast(i)), elem, dst + i * elem.size, false);
    }

    /// the C copies back into their tables
    pub fn writeBack(c: *Conv) Error!void {
        const vm = c.th.vm;
        for (c.writebacks.items) |w| {
            if (w.list) {
                for (0..w.n) |i| {
                    const old = w.table.getInt(@intCast(i));
                    const mem = w.mem + i * w.ty.size;
                    if (w.ty.kind == .@"struct" and old.asTable() != null) {
                        fillTable(vm, w.ty, mem, old.asTable().?, false);
                    } else {
                        w.table.set(vm.gpa, .{ .int = @intCast(i) }, fromC(vm, w.ty, mem, .null));
                    }
                }
            } else {
                fillTable(vm, w.ty, w.mem, w.table, false);
            }
        }
    }
};

fn store(comptime T: type, dst: [*]u8, v: T) void {
    @as(*align(1) T, @ptrCast(dst)).* = v;
}

fn load(comptime T: type, src: [*]const u8) T {
    return @as(*align(1) const T, @ptrCast(src)).*;
}

/// the fields of the struct at src into the table tbl (by name); a fresh
/// table has none of the keys yet and is filled without lookups
fn fillTable(vm: *VM, t: *Type, src: [*]const u8, tbl: *Table, fresh: bool) void {
    for (t.fields) |f| {
        const v = fromC(vm, f.ty, src + f.offset, .null);
        if (fresh and v != .null and !f.key.isMeta()) {
            tbl.addFresh(vm.gpa, f.key, v);
        } else {
            tbl.setStr(vm.gpa, f.key, v);
        }
    }
}

/// The value of type t at src as a slang value. Pointers in it keep owner
/// alive.
pub fn fromC(vm: *VM, t: *Type, src: [*]const u8, owner: Value) Value {
    return switch (t.kind) {
        .void => .null,
        .bool, .i8, .u8, .i16, .u16, .i32, .u32, .i64, .u64, .f32, .f64 => scalarGet(t, src),
        .pointer => newPointer(vm, load(usize, src), t.elem, owner),
        .function => newPointer(vm, load(usize, src), null, owner),
        .string => blk: {
            const a = load(usize, src);
            if (a == 0) break :blk .null;
            break :blk vm.str(std.mem.span(@as([*:0]const u8, @ptrFromInt(a))));
        },
        .@"struct" => blk: {
            const tbl = vm.newTable(0, t.fields.len);
            fillTable(vm, t, src, tbl, true);
            break :blk .{ .table = tbl };
        },
        .array => blk: {
            const elem = t.elem.?;
            if (elem.char) {
                const n = std.mem.indexOfScalar(u8, src[0..t.count], 0) orelse t.count;
                break :blk vm.str(src[0..n]);
            }
            const tbl = vm.newTable(t.count, 0);
            for (0..t.count) |i| tbl.append(vm.gpa, fromC(vm, elem, src + i * elem.size, owner));
            break :blk .{ .table = tbl };
        },
    };
}
