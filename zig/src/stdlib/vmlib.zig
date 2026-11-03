const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Proto = vm_mod.Proto;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const object = @import("../vm/object.zig");
const gc = @import("../vm/gc.zig");

/// slang/vm: access to closures, upvalues and bytecode, and the collector.
pub fn module(vm: *VM) *Table {
    const m = stdlib.makeModule(vm, &.{
        .{ .name = "set_upvalue", .f = vmSetUpvalue },
        .{ .name = "get_upvalue", .f = vmGetUpvalue },
        .{ .name = "upvalue_names", .f = vmUpvalueNames },
        .{ .name = "load_bytecode", .f = vmLoadBytecode },
        .{ .name = "load_bytes", .f = vmLoadBytes },
        .{ .name = "to_bytes", .f = vmToBytes },
        .{ .name = "embedded", .f = vmEmbedded },
        .{ .name = "build_id", .f = vmBuildId },
        .{ .name = "features", .f = vmFeatures },
        .{ .name = "disassemble", .f = vmDisassemble },
        .{ .name = "load_proto", .f = vmLoadProto },
        .{ .name = "load_native", .f = @import("../loader.zig").loadNative },
        .{ .name = "find_native", .f = @import("../loader.zig").findNative },
        .{ .name = "collect", .f = vmCollect },
        .{ .name = "on_collect", .f = vmOnCollect },
        .{ .name = "weak_keys", .f = vmWeakKeys },
        .{ .name = "weak_values", .f = vmWeakValues },
        .{ .name = "weak", .f = vmWeak },
    });
    m.set(vm.gpa, vm.str("gc"), .{ .table = gcObject(vm) });
    return m;
}

// ------------------------------------------------------------ collector

/// collect(): a full collection now; what nothing refers to any more is
/// freed (finalizers run) before it returns.
fn vmCollect(th: *Thread, args: []Value) Error!Value {
    _ = args;
    gc.collect(th.vm);
    gc.runFinalizers(th.vm);
    return .null;
}

/// on_collect(v, f): f(v) runs once v is unreachable, after the collection
/// that found it so (one finalizer per object: a second call replaces the
/// first, null removes it). v is kept alive until f has run and freed by a
/// later collection, unless f made it reachable again.
fn vmOnCollect(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const v = api.arg(args, 0);
    const o = v.heapObject() orelse return vm.raise("vm.on_collect: a {s} is not collected", .{v.typeName()});
    switch (o.kind) {
        .table, .userdata, .closure, .thread => {},
        else => return vm.raise("vm.on_collect: a {s} is not collected", .{v.typeName()}),
    }
    const f = api.arg(args, 1);
    if (f == .null) {
        _ = vm.finalizers.remove(o);
        return .null;
    }
    if (f != .function) return api.argError(th, "f", 1, "function", f);
    vm.finalizers.put(vm.gpa, o, .{ .obj = v, .f = f }) catch oom();
    return .null;
}

fn weakTable(vm: *VM, mode: @import("../vm/table.zig").Weak) *Table {
    const t = vm.newTable(0, 0);
    t.weak = mode;
    vm.weak_tables.append(vm.gpa, t) catch oom();
    return t;
}

/// weak_keys(): a table whose keys do not keep their entries alive
fn vmWeakKeys(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .table = weakTable(th.vm, .keys) };
}

/// weak_values(): a table whose values do not keep their entries alive
fn vmWeakValues(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .table = weakTable(th.vm, .values) };
}

/// weak(v): {value: v}, weakly
fn vmWeak(th: *Thread, args: []Value) Error!Value {
    const t = weakTable(th.vm, .values);
    t.set(th.vm.gpa, th.vm.str("value"), api.arg(args, 0));
    return .{ .table = t };
}

/// gc: the collector of this VM (each isolate has its own), with its
/// settings and counters as properties.
fn gcObject(vm: *VM) *Table {
    const meta = vm.newTable(0, 4);
    meta.set(vm.gpa, vm.str("__type"), vm.str("vm.Collector"));
    stdlib.setClass(vm, meta, &.{}, &.{
        .{ .name = "growth", .get = gcGrowth, .set = gcSetGrowth },
        .{ .name = "minimum", .get = gcMinimum, .set = gcSetMinimum },
        .{ .name = "automatic", .get = gcAutomatic, .set = gcSetAutomatic },
        .{ .name = "in_use", .get = gcInUse },
        .{ .name = "next", .get = gcNext },
        .{ .name = "collections", .get = gcCollections },
    });
    const t = vm.newTable(0, 0);
    t.meta = meta;
    return t;
}

fn gcGrowth(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .float = th.vm.gc_growth };
}

fn gcSetGrowth(th: *Thread, args: []Value) Error!Value {
    const g = try api.argNumber(th, args, 1, "growth");
    if (!(g >= 1.1) or std.math.isInf(g)) return th.vm.raise("vm: gc.growth must be a number of at least 1.1, got {d}", .{g});
    th.vm.gc_growth = g;
    gc.schedule(th.vm);
    return .null;
}

fn gcMinimum(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .int = @intCast(th.vm.gc_minimum) };
}

fn gcSetMinimum(th: *Thread, args: []Value) Error!Value {
    const n = try api.argInt(th, args, 1, "minimum");
    if (n < 0) return th.vm.raise("vm: gc.minimum must not be negative, got {d}", .{n});
    th.vm.gc_minimum = @intCast(n);
    gc.schedule(th.vm);
    return .null;
}

fn gcAutomatic(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .bool = th.vm.gc_automatic };
}

fn gcSetAutomatic(th: *Thread, args: []Value) Error!Value {
    const v = api.arg(args, 1);
    if (v != .bool) return api.argError(th, "automatic", 1, "bool", v);
    th.vm.gc_automatic = v.bool;
    gc.schedule(th.vm);
    return .null;
}

fn gcInUse(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .int = @intCast(th.vm.bytes_allocated) };
}

/// the bytes in use at which the next automatic collection runs; null
/// while collections are not automatic
fn gcNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    if (!th.vm.gc_automatic) return .null;
    return .{ .int = @intCast(th.vm.next_gc) };
}

fn gcCollections(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return .{ .int = @intCast(th.vm.collections) };
}

/// load_proto(proto, [env]): turns a prototype table produced by the
/// compiler into a function whose globals are env (a table; the global
/// table by default). Layout:
///
///   {code: {ints}, locations: {{pc, origin, line, column}}, constants: {{kind, value}},
///    upvalues: {{name, index, is_local}}, children: {proto}, max_stack, nargs, is_vararg,
///    name}
fn vmLoadProto(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "proto");
    const p = try protoFromTable(th, t, 0);
    const env = api.arg(args, 1);
    if (env == .null) return .{ .function = th.vm.load(p) };
    const e = env.asTable() orelse return api.argError(th, "env", 1, "table", env);
    return .{ .function = th.vm.loadWithEnv(p, e) };
}

fn protoFromTable(th: *Thread, t: *Table, depth: usize) Error!*Proto {
    const vm = th.vm;
    const gpa = vm.gpa;
    if (depth > 200) return vm.raise("load_proto: nesting too deep", .{});
    const p = vm.newProto();
    p.max_stack = @intCast(@max(0, t.getName("max_stack").asInt()));
    p.nargs = @intCast(@max(0, t.getName("nargs").asInt()));
    p.is_vararg = t.getName("is_vararg").truthy();
    const name = t.getName("name");
    if (name.asBytes() != null) p.name = th.renderString(name);
    const code = t.getName("code").asTable() orelse return vm.raise("load_proto: missing code", .{});
    p.code = gpa.alloc(u32, code.len()) catch oom();
    var it = code.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        if (e.val != .int) return vm.raise("load_proto: instruction is not an int", .{});
        p.code[i] = @truncate(@as(u64, @bitCast(e.val.int)));
    }
    if (t.getName("locations").asTable()) |locs| {
        var list: std.ArrayList(object.LocInfo) = .empty;
        var lit = locs.iterator();
        while (lit.next()) |e| {
            const lt = e.val.asTable() orelse continue;
            list.append(gpa, .{
                .first_pc = @intCast(@max(0, lt.getInt(0).asInt())),
                .origin = th.renderString(lt.getInt(1)),
                .line = @intCast(@max(0, lt.getInt(2).asInt())),
                .column = @intCast(@max(0, lt.getInt(3).asInt())),
            }) catch oom();
        }
        p.locs = list.toOwnedSlice(gpa) catch oom();
    }
    if (t.getName("locals").asTable()) |locals| {
        var list: std.ArrayList(object.LocalVar) = .empty;
        var lit = locals.iterator();
        while (lit.next()) |e| {
            const lt = e.val.asTable() orelse continue;
            list.append(gpa, .{
                .name = th.renderString(lt.getInt(0)),
                .reg = @intCast(@max(0, lt.getInt(1).asInt())),
                .start_pc = @intCast(@max(0, lt.getInt(2).asInt())),
                .end_pc = @intCast(@max(0, lt.getInt(3).asInt())),
            }) catch oom();
        }
        p.locals = list.toOwnedSlice(gpa) catch oom();
    }
    if (t.getName("constants").asTable()) |consts| {
        var list: std.ArrayList(Value) = .empty;
        var cit = consts.iterator();
        while (cit.next()) |e| {
            const ct = e.val.asTable() orelse return vm.raise("load_proto: constant must be {{kind, value}}", .{});
            const kind = ct.getInt(0).asBytes() orelse "";
            var val = ct.getInt(1);
            if (std.mem.eql(u8, kind, "int")) {
                if (val == .float) val = .{ .int = @import("core.zig").floatToInt(val.float) };
            } else if (std.mem.eql(u8, kind, "double")) {
                if (val == .int) val = .{ .float = @floatFromInt(val.int) };
            } else if (std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "bool")) {
                // as is
            } else if (std.mem.eql(u8, kind, "null")) {
                val = .null;
            } else {
                return vm.raise("load_proto: unknown constant kind \"{s}\"", .{kind});
            }
            list.append(gpa, val) catch oom();
        }
        p.consts = list.toOwnedSlice(gpa) catch oom();
    }
    if (t.getName("upvalues").asTable()) |ups| {
        var list: std.ArrayList(object.UpvalDesc) = .empty;
        var uit = ups.iterator();
        while (uit.next()) |e| {
            const ut = e.val.asTable() orelse return vm.raise("load_proto: upvalue must be {{name, index, is_local}}", .{});
            list.append(gpa, .{
                .name = th.renderString(ut.getInt(0)),
                .index = @intCast(@max(0, ut.getInt(1).asInt())),
                .is_local = ut.getInt(2).truthy(),
            }) catch oom();
        }
        p.upvals = list.toOwnedSlice(gpa) catch oom();
    }
    if (t.getName("children").asTable()) |children| {
        var list: std.ArrayList(*Proto) = .empty;
        var chit = children.iterator();
        while (chit.next()) |e| {
            const ct = e.val.asTable() orelse return vm.raise("load_proto: child must be a table", .{});
            list.append(gpa, try protoFromTable(th, ct, depth + 1)) catch oom();
        }
        p.children = list.toOwnedSlice(gpa) catch oom();
    }
    return p;
}

fn vmSetUpvalue(th: *Thread, args: []Value) Error!Value {
    const cl = try api.argFunction(th, args, 0, "closure");
    const name = try api.argString(th, args, 1, "name");
    if (cl.upvalueIndex(name)) |i| {
        // a fresh closed cell: other closures sharing the old one are not
        // affected (this is how module{} works)
        cl.upvals[i] = th.vm.newUpvalue(api.arg(args, 2));
    }
    return .null;
}

fn vmGetUpvalue(th: *Thread, args: []Value) Error!Value {
    const cl = try api.argFunction(th, args, 0, "closure");
    const name = try api.argString(th, args, 1, "name");
    const i = cl.upvalueIndex(name) orelse return .null;
    return cl.getUpvalue(i);
}

fn vmUpvalueNames(th: *Thread, args: []Value) Error!Value {
    const cl = try api.argFunction(th, args, 0, "closure");
    const t = th.vm.newTable(0, 0);
    if (cl.proto) |p| {
        for (p.upvals) |u| t.append(th.vm.gpa, .{ .string = u.name });
    }
    return .{ .table = t };
}

fn vmLoadBytecode(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const path = try api.argString(th, args, 0, "path");
    const data = std.Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |e| {
        return vm.raise("cannot read {s}: {t}", .{ path, e });
    };
    defer vm.gpa.free(data);
    const cl = vm.loadBytes(data) catch |e| {
        if (e == error.Slang) {
            var err = vm.takeError();
            defer err.deinit(vm.gpa);
            return vm.raise("{s}: {s}", .{ path, err.message });
        }
        return e;
    };
    return .{ .function = cl };
}

fn vmLoadBytes(th: *Thread, args: []Value) Error!Value {
    const data = try api.argString(th, args, 0, "bytes");
    return .{ .function = try th.vm.loadBytes(data) };
}

fn vmToBytes(th: *Thread, args: []Value) Error!Value {
    const cl = try api.argFunction(th, args, 0, "closure");
    const p = cl.proto orelse return th.vm.raise("cannot serialise a native function", .{});
    const bytes = vm_mod.slb.encode(th.vm.gpa, p, api.argBool(args, 1, false));
    defer th.vm.gpa.free(bytes);
    return th.vm.str(bytes);
}

fn vmEmbedded(th: *Thread, args: []Value) Error!Value {
    const name = try api.argString(th, args, 0, "name");
    return Value.fromClosure(try th.vm.embeddedModule(name));
}

fn vmDisassemble(th: *Thread, args: []Value) Error!Value {
    const cl = try api.argFunction(th, args, 0, "closure");
    const p = cl.proto orelse {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "native function {s}", .{cl.nameBytes()}) catch "native function";
        return th.vm.str(s);
    };
    var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
    defer aw.deinit();
    vm_mod.disasm.disassemble(&aw.writer, p) catch oom();
    return th.vm.str(aw.writer.buffered());
}

/// features(): the optional parts of the ISA this VM runs, as a set
/// ({fused: true}); the compiler emits core bytecode for what is missing.
/// SLANG_ISA=core hides the fused instructions, which makes the compiler
/// emit core bytecode only.
fn vmFeatures(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const t = vm.newTable(0, 1);
    const isa = vm.getenv("SLANG_ISA");
    if (isa == null or !std.mem.eql(u8, isa.?, "core")) t.set(vm.gpa, vm.str("fused"), .{ .bool = true });
    return .{ .table = t };
}

/// build_id(): a hash of the embedded seed bytecode, as 16 hex digits; the
/// bytecode cache keys on it so that a new compiler never serves entries
/// compiled by an old one.
fn vmBuildId(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const lib = &th.vm.lib;
    if (lib.build_id == null) {
        var h = std.hash.Wyhash.init(0x5eed);
        for (th.vm.embedded) |f| {
            h.update(f.name);
            h.update(f.data);
        }
        const digest = h.final();
        var buf: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>16}", .{digest}) catch unreachable;
        lib.build_id = buf;
    }
    return th.vm.str(&lib.build_id.?);
}
