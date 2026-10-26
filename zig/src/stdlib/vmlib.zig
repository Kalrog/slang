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

/// slang/vm: access to closures, upvalues and bytecode.
pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "setUpvalue", .f = vmSetUpvalue },
        .{ .name = "getUpvalue", .f = vmGetUpvalue },
        .{ .name = "upvalueNames", .f = vmUpvalueNames },
        .{ .name = "load_bytecode", .f = vmLoadBytecode },
        .{ .name = "load_bytes", .f = vmLoadBytes },
        .{ .name = "to_bytes", .f = vmToBytes },
        .{ .name = "embedded", .f = vmEmbedded },
        .{ .name = "disassemble", .f = vmDisassemble },
        .{ .name = "load_proto", .f = vmLoadProto },
    });
}

/// load_proto(proto): turns a prototype table produced by the compiler into
/// a function. Layout:
///
///   {code: {ints}, locations: {{pc, origin, line, column}}, constants: {{kind, value}},
///    upvalues: {{name, index, is_local}}, children: {proto}, max_stack, nargs, is_vararg}
fn vmLoadProto(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "proto");
    const p = try protoFromTable(th, t, 0);
    return .{ .function = th.vm.load(p) };
}

fn protoFromTable(th: *Thread, t: *Table, depth: usize) Error!*Proto {
    const vm = th.vm;
    const gpa = vm.gpa;
    if (depth > 200) return vm.raise("load_proto: nesting too deep", .{});
    const p = vm.newProto();
    p.max_stack = @intCast(@max(0, t.getName("max_stack").asInt()));
    p.nargs = @intCast(@max(0, t.getName("nargs").asInt()));
    p.is_vararg = t.getName("is_vararg").truthy();
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
