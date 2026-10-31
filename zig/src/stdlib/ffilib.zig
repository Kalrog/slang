//! slang/ffi_core: calling C through libffi, without writing C: shared
//! libraries, their symbols, and functions made from a symbol and a
//! signature. The types, pointers and conversions are slang/ctypes'
//! (ctypes.zig), which every build has; this module needs libffi.
//!
//! Arguments convert as ctypes describes; a table given for a pointer
//! parameter marked for writeback gets the memory back after the call
//! (out parameters), and a buffer is passed as its memory.

const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const ctypes = @import("ctypes.zig");
const Type = ctypes.Type;
const FfiType = ctypes.FfiType;
const Ptr = ctypes.Ptr;

// ------------------------------------------------------------ libffi

extern fn ffi_prep_cif(cif: *Cif, abi: c_uint, nargs: c_uint, rtype: *FfiType, atypes: ?[*]*FfiType) c_int;
extern fn ffi_prep_cif_var(cif: *Cif, abi: c_uint, nfixed: c_uint, ntotal: c_uint, rtype: *FfiType, atypes: ?[*]*FfiType) c_int;
extern fn ffi_call(cif: *Cif, f: *const anyopaque, rvalue: ?*anyopaque, avalue: ?[*]?*anyopaque) void;

const FFI_OK: c_int = 0;
const default_abi: c_uint = switch (builtin.cpu.arch) {
    .aarch64 => if (builtin.os.tag == .windows) 2 else 1, // FFI_WIN64 / FFI_SYSV
    .x86_64 => if (builtin.os.tag == .windows) 1 else 2, // FFI_WIN64 / FFI_UNIX64
    .wasm32 => 2, // FFI_WASM32_EMSCRIPTEN
    else => @compileError("ffi: unsupported architecture"),
};

/// Under Emscripten nothing is loaded at run time: the C libraries are linked
/// into the program, and a generated table (see website/web/) gives their
/// symbols by name. Every library "opens" as that table.
const static_symbols = builtin.os.tag == .emscripten;
extern "c" fn slang_ffi_static_symbol(name: [*:0]const u8) ?*anyopaque;
var static_handle: u8 = 0;

/// ffi_cif, kept opaque: libffi's layout differs between targets, so it is
/// given more room than any of them needs.
const Cif = extern struct { space: [16]usize align(16) };

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
const RTLD_NOW: c_int = 2;

const library_tname = "ffi.library";
const func_tname = "ffi.func";

const Func = struct {
    f: *const anyopaque,
    cif: Cif,
    ret: *Type,
    args: []*Type,
    ffi_args: []*FfiType,
    /// pointer parameters whose memory is copied back to the table given
    writeback: []bool,
    variadic: bool,
    name: []const u8,
};

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "open", .f = ffiOpen },
        .{ .name = "symbol", .f = ffiSymbol },
        .{ .name = "func", .f = ffiFunc },
    });
}

// ------------------------------------------------------------ libraries

/// open(path) -> a library (dlopen), or {null, message}; path null is the
/// program itself
fn ffiOpen(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    var h: ?*anyopaque = null;
    if (static_symbols) {
        h = &static_handle;
    } else if (api.arg(args, 0) == .null) {
        h = dlopen(null, RTLD_NOW);
    } else {
        const path = try api.argString(th, args, 0, "path");
        const z = vm.gpa.dupeSentinel(u8, path, 0) catch oom();
        defer vm.gpa.free(z);
        h = dlopen(z.ptr, RTLD_NOW);
    }
    if (h == null) {
        const msg = if (dlerror()) |e| std.mem.span(e) else "cannot open";
        const t = vm.newTable(2, 0);
        t.append(vm.gpa, .null);
        t.append(vm.gpa, vm.str(msg));
        return .{ .table = t };
    }
    const u = vm.newUserdataOf(?*anyopaque, h, library_tname, null);
    return .{ .userdata = u };
}

/// symbol(library, name) -> a pointer to the symbol, or null
fn ffiSymbol(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const h = (try api.argUserdata(th, args, 0, "library", ?*anyopaque, library_tname)).*;
    const name = try api.argString(th, args, 1, "name");
    const z = vm.gpa.dupeSentinel(u8, name, 0) catch oom();
    defer vm.gpa.free(z);
    const p = (if (static_symbols) slang_ffi_static_symbol(z.ptr) else dlsym(h, z.ptr)) orelse return .null;
    return ctypes.newPointer(vm, @intFromPtr(p), null, .null);
}

// ------------------------------------------------------------ functions

/// func(symbol, ret, {args...}, name, [{writeback...}], [variadic]) -> a
/// function calling the C function at symbol with that signature
fn ffiFunc(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const sym = ctypes.asPointer(api.arg(args, 0)) orelse return api.argError(th, "symbol", 0, ctypes.pointer_tname, api.arg(args, 0));
    const ret = try ctypes.argType(th, args, 1, "ret");
    const list = try api.argTable(th, args, 2, "args");
    const name = try api.argString(th, args, 3, "name");
    const wb = api.arg(args, 4).asTable();
    const variadic = api.argBool(args, 5, false);
    const n = list.arrayLen();
    const types = vm.gpa.alloc(*Type, n) catch oom();
    const ffi_types = vm.gpa.alloc(*FfiType, n + 1) catch oom();
    const writeback = vm.gpa.alloc(bool, n) catch oom();
    for (0..n) |i| {
        const t = ctypes.asType(list.getInt(@intCast(i))) orelse return vm.raise("ffi.func: argument {d} of {s} has no type", .{ i, name });
        if (!t.complete or t.kind == .void or t.kind == .array) return vm.raise("ffi.func: argument {d} of {s} cannot be a {s}", .{ i, name, t.name });
        types[i] = t;
        ffi_types[i] = t.ffi;
        writeback[i] = if (wb) |w| w.getInt(@intCast(i)).truthy() else false;
    }
    if (!ret.complete or ret.kind == .array) return vm.raise("ffi.func: {s} cannot return a {s}", .{ name, ret.name });
    const f = vm.gpa.create(Func) catch oom();
    f.* = .{
        .f = @ptrFromInt(sym.as(Ptr).addr),
        .cif = undefined,
        .ret = ret,
        .args = types,
        .ffi_args = ffi_types,
        .writeback = writeback,
        .variadic = variadic,
        .name = vm.gpa.dupe(u8, name) catch oom(),
    };
    if (!variadic and ffi_prep_cif(&f.cif, default_abi, @intCast(n), ret.ffi, ffi_types.ptr) != FFI_OK) {
        return vm.raise("ffi.func: libffi cannot call {s}", .{name});
    }
    const holder = vm.newUserdataOf(*Func, f, func_tname, null);
    holder.owner = .{ .userdata = sym };
    const cl = vm.newNative(name, callFunc, &.{.{ .userdata = holder }});
    return .{ .function = cl };
}

/// The C type a variadic argument is passed as (C's default promotions).
fn variadicType(vm: *VM, v: Value) Error!*Type {
    return switch (v) {
        .int => |i| ctypes.primitive(if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) "int32" else "int64").?,
        .bool => ctypes.primitive("int32").?,
        .float => ctypes.primitive("double").?,
        .string => ctypes.primitive("string").?,
        .null, .userdata => ctypes.primitive("pointer").?,
        else => vm.raise("ffi: a {s} cannot be a variadic argument", .{v.typeName()}),
    };
}

fn callFunc(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const f = th.currentClosure().nvals[0].userdata.as(*Func).*;
    const fixed = f.args.len;
    if (args.len < fixed or (args.len > fixed and !f.variadic)) {
        return vm.raise("{s} takes {d} arguments, got {d}", .{ f.name, fixed, args.len });
    }
    var arena_state = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conv = ctypes.Conv{ .th = th, .arena = arena };
    const total = args.len;
    const values = arena.alloc(?*anyopaque, total + 1) catch oom();
    var types = f.args;
    var cif_ptr = &f.cif;
    if (f.variadic) {
        types = arena.alloc(*Type, total) catch oom();
        const ffi_types = arena.alloc(*FfiType, total + 1) catch oom();
        for (0..total) |i| {
            types[i] = if (i < fixed) f.args[i] else try variadicType(vm, args[i]);
            ffi_types[i] = types[i].ffi;
        }
        const cif = arena.create(Cif) catch oom();
        if (ffi_prep_cif_var(cif, default_abi, @intCast(fixed), @intCast(total), f.ret.ffi, ffi_types.ptr) != FFI_OK) {
            return vm.raise("{s}: libffi cannot make this call", .{f.name});
        }
        cif_ptr = cif;
    }
    var what_buf: [128]u8 = undefined;
    for (0..total) |i| {
        const t = types[i];
        const mem = arena.alignedAlloc(u8, .@"16", @max(t.size, 8)) catch oom();
        @memset(mem, 0);
        conv.what = std.fmt.bufPrint(&what_buf, "bad argument #{d} to '{s}'", .{ i + 1, f.name }) catch "bad argument";
        try conv.toC(args[i], t, mem.ptr, i < fixed and f.writeback[i]);
        values[i] = mem.ptr;
    }
    // integer results narrower than a register come back widened
    const rmem = arena.alignedAlloc(u8, .@"16", @max(f.ret.size, 16)) catch oom();
    ffi_call(cif_ptr, f.f, rmem.ptr, values.ptr);
    try conv.writeBack();
    return ctypes.fromC(vm, f.ret, rmem.ptr, .null);
}
