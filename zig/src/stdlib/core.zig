const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const Native = stdlib.Native;

pub fn open(vm: *VM) void {
    const core = [_]Native{
        .{ .name = "print", .f = corePrint },
        .{ .name = "args", .f = coreArgs },
        .{ .name = "readLine", .f = coreReadLine },
        .{ .name = "assert", .f = coreAssert },
        .{ .name = "append", .f = coreAppend },
        .{ .name = "remove", .f = coreRemove },
        .{ .name = "keys", .f = coreKeys },
        .{ .name = "values", .f = coreValues },
        .{ .name = "entries", .f = coreEntries },
        .{ .name = "concat", .f = coreConcat },
        .{ .name = "error", .f = coreError },
        .{ .name = "len", .f = coreLen },
        .{ .name = "type", .f = coreType },
        .{ .name = "set_raw", .f = coreSetRaw },
        .{ .name = "get_raw", .f = coreGetRaw },
        .{ .name = "to_int", .f = coreToInt },
        .{ .name = "string", .f = coreString },
        .{ .name = "list_push", .f = coreListPush },
        .{ .name = "raise", .f = coreRaise },
        .{ .name = "open", .f = @import("file.zig").coreOpen },
    };
    for (core) |n| vm.register(n.name, n.f);
    @import("file.zig").init(vm);

    const pcall = vm.newNative("pcall", pcallNative, &.{});
    pcall.special = .pcall;
    vm.setGlobal("pcall", .{ .function = pcall });
}

fn pcallNative(th: *Thread, args: []Value) Error!Value {
    _ = args;
    return th.vm.raise("pcall must be called from slang", .{});
}

/// Renders every argument (through __tostring) into one buffer. Arguments
/// are re-read from the stack because __tostring may move it.
fn renderArgs(th: *Thread, from: usize, aw: *std.Io.Writer.Allocating) Error!void {
    var i = from;
    while (i < th.nargs()) : (i += 1) {
        const s = try th.toString(th.arg(i));
        aw.writer.writeAll(s.bytes()) catch oom();
    }
}

fn corePrint(th: *Thread, args: []Value) Error!Value {
    _ = args;
    var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
    defer aw.deinit();
    try renderArgs(th, 0, &aw);
    th.vm.out().writeAll(aw.writer.buffered()) catch return th.vm.raise("write error on stdout", .{});
    return .null;
}

fn coreArgs(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const t = vm.newTable(vm.args.len, 0);
    for (vm.args) |a| t.append(vm.gpa, vm.str(a));
    return .{ .table = t };
}

fn coreReadLine(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    vm.flush();
    const line = vm.stdin.interface.takeDelimiter('\n') catch return .null;
    const l = line orelse return .null;
    return vm.str(std.mem.trimEnd(u8, l, "\r\n"));
}

fn coreAssert(th: *Thread, args: []Value) Error!Value {
    if (api.arg(args, 0).truthy()) return .null;
    var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
    defer aw.deinit();
    for (args[@min(1, args.len)..]) |a| vm_mod.format.writeValue(&aw.writer, a) catch oom();
    const msg = aw.writer.buffered();
    return th.vm.raiseMsg(if (msg.len == 0) "assertion failed" else msg);
}

fn coreAppend(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    t.set(th.vm.gpa, .{ .int = @intCast(t.len()) }, api.arg(args, 1));
    return .null;
}

/// list_push(t, v): appends v to the array part of t, keeping null slots.
fn coreListPush(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    t.pushSlot(th.vm.gpa, api.arg(args, 1));
    return .null;
}

fn coreRemove(th: *Thread, args: []Value) Error!Value {
    const t = api.arg(args, 0).asTable() orelse return .null;
    return t.remove(th.vm.gpa, api.arg(args, 1));
}

/// A snapshot of the keys of t as an array table (iteration order).
fn keysOf(vm: *VM, t: *const Table) *Table {
    const keys = vm.newTable(t.len(), 0);
    var it = t.iterator();
    while (it.next()) |e| keys.pushSlot(vm.gpa, e.key);
    return keys;
}

// The iterators keep {keys snapshot, position, source table} in the native
// closure's nvals.

fn keysNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const cl = th.currentClosure();
    const keys = cl.nvals[0].table;
    const i: usize = @intCast(cl.nvals[1].int);
    if (i < keys.arrayLen()) {
        cl.nvals[1] = .{ .int = @intCast(i + 1) };
        return keys.getInt(@intCast(i));
    }
    return .null;
}

fn valuesNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const cl = th.currentClosure();
    const keys = cl.nvals[0].table;
    const i: usize = @intCast(cl.nvals[1].int);
    if (i < keys.arrayLen()) {
        cl.nvals[1] = .{ .int = @intCast(i + 1) };
        return cl.nvals[2].table.get(keys.getInt(@intCast(i)));
    }
    return .null;
}

fn entriesNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const cl = th.currentClosure();
    const keys = cl.nvals[0].table;
    const i: usize = @intCast(cl.nvals[1].int);
    if (i < keys.arrayLen()) {
        cl.nvals[1] = .{ .int = @intCast(i + 1) };
        const k = keys.getInt(@intCast(i));
        const pair = th.vm.newTable(2, 0);
        pair.pushSlot(th.vm.gpa, k);
        pair.pushSlot(th.vm.gpa, cl.nvals[2].table.get(k));
        return .{ .table = pair };
    }
    return .null;
}

fn coreKeys(th: *Thread, args: []Value) Error!Value {
    const t = api.arg(args, 0).asTable() orelse return .null;
    const keys = keysOf(th.vm, t);
    return .{ .function = th.vm.newNative("keys.next", keysNext, &.{ .{ .table = keys }, .{ .int = 0 }, .{ .table = t } }) };
}

fn iterTable(th: *Thread, args: []Value, name: []const u8) Error!*Table {
    const a = api.arg(args, 0);
    return switch (a) {
        .null => th.vm.newTable(0, 0),
        .table => |t| t,
        else => th.vm.raise("{s} expects a table, got {s}", .{ name, a.typeName() }),
    };
}

fn coreValues(th: *Thread, args: []Value) Error!Value {
    const t = try iterTable(th, args, "values");
    const keys = keysOf(th.vm, t);
    return .{ .function = th.vm.newNative("values.next", valuesNext, &.{ .{ .table = keys }, .{ .int = 0 }, .{ .table = t } }) };
}

fn coreEntries(th: *Thread, args: []Value) Error!Value {
    const t = try iterTable(th, args, "entries");
    const keys = keysOf(th.vm, t);
    return .{ .function = th.vm.newNative("entries.next", entriesNext, &.{ .{ .table = keys }, .{ .int = 0 }, .{ .table = t } }) };
}

fn coreConcat(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    switch (api.arg(args, 0)) {
        .string => {
            var aw: std.Io.Writer.Allocating = .init(vm.gpa);
            defer aw.deinit();
            try renderArgs(th, 0, &aw);
            return vm.str(aw.writer.buffered());
        },
        .table => {
            const out = vm.newTable(0, 0);
            for (args, 0..) |a, i| {
                const t = a.asTable() orelse return vm.raise("concat: argument {d} is not a table", .{i});
                out.addAll(vm.gpa, t);
            }
            return .{ .table = out };
        },
        else => return vm.raise("concat requires a table or string", .{}),
    }
}

fn coreError(th: *Thread, args: []Value) Error!Value {
    _ = args;
    var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
    defer aw.deinit();
    try renderArgs(th, 0, &aw);
    return th.vm.raiseMsg(aw.writer.buffered());
}

/// raise(err): raises an error again; err is an error table ({message,
/// location, stack}, as produced by pcall) or a string. The original
/// location and stack are kept.
fn coreRaise(th: *Thread, args: []Value) Error!Value {
    th.vm.setErrorFromValue(api.arg(args, 0));
    return error.Slang;
}

fn coreLen(th: *Thread, args: []Value) Error!Value {
    return th.len(api.arg(args, 0));
}

fn coreType(th: *Thread, args: []Value) Error!Value {
    return th.typeOf(api.arg(args, 0));
}

fn coreSetRaw(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    t.set(th.vm.gpa, api.arg(args, 1), api.arg(args, 2));
    return .null;
}

fn coreGetRaw(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    return t.get(api.arg(args, 1));
}

fn coreToInt(th: *Thread, args: []Value) Error!Value {
    const a = api.arg(args, 0);
    switch (a) {
        .int => return a,
        .float => |f| return .{ .int = floatToInt(f) },
        .string => |s| {
            const str = s.bytes();
            var body = str;
            var neg = false;
            var base: u8 = 10;
            if (std.mem.startsWith(u8, body, "-")) {
                neg = true;
                body = body[1..];
            } else if (std.mem.startsWith(u8, body, "+")) {
                body = body[1..];
            }
            if (std.mem.startsWith(u8, body, "0x") or std.mem.startsWith(u8, body, "0X")) {
                base = 16;
                body = body[2..];
            }
            const n = parseIntStrict(body, base) orelse return th.vm.raise("FormatException: Invalid number: \"{s}\"", .{str});
            return .{ .int = if (neg) 0 -% n else n };
        },
        else => return th.vm.raise("toInt requires an integer or string", .{}),
    }
}

/// Like Go's strconv.ParseInt without a sign: digits only, no separators.
pub fn parseIntStrict(s: []const u8, base: u8) ?i64 {
    if (s.len == 0) return null;
    var n: i64 = 0;
    for (s) |c| {
        const dgt = std.fmt.charToDigit(c, base) catch return null;
        n = std.math.mul(i64, n, base) catch return null;
        n = std.math.add(i64, n, dgt) catch return null;
    }
    return n;
}

/// Dart/Go style saturating conversion (Go's is implementation defined on
/// overflow; Dart saturates).
pub fn floatToInt(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    if (f >= 9223372036854775807.0) return std.math.maxInt(i64);
    if (f <= -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(f);
}

fn coreString(th: *Thread, args: []Value) Error!Value {
    return .{ .string = try th.toString(api.arg(args, 0)) };
}
