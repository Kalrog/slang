const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const TableEntry = @import("../vm/table.zig").Entry;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const ctypes = @import("ctypes.zig");
const Native = stdlib.Native;

pub fn open(vm: *VM) void {
    const core = [_]Native{
        .{ .name = "print", .f = corePrint },
        .{ .name = "args", .f = coreArgs },
        .{ .name = "assert", .f = coreAssert },
        stdlib.fast("append", coreAppend),
        stdlib.fast("remove", coreRemove),
        stdlib.fast("delete", coreDelete),
        stdlib.fast("has", coreHas),
        .{ .name = "keys", .f = coreKeys },
        .{ .name = "values", .f = coreValues },
        .{ .name = "entries", .f = coreEntries },
        .{ .name = "concat", .f = coreConcat },
        stdlib.fast("len", coreLen),
        stdlib.fast("count", coreCount),
        stdlib.fast("same", coreSame),
        stdlib.fast("type", coreType),
        stdlib.fast("raw_type", coreRawType),
        stdlib.fast("set_raw", coreSetRaw),
        stdlib.fast("get_raw", coreGetRaw),
        stdlib.fast("to_int", coreToInt),
        stdlib.fast("to_float", coreToFloat),
        .{ .name = "string", .f = coreString },
        .{ .name = "raise", .f = coreRaise },
    };
    for (core) |n| vm.setGlobal(n.name, n.value(vm));
    vm.setGlobal("stop", .{ .userdata = vm.stop_value });
    // error is the error library, a table: slang/std adds its functions
    // (error.new, error.wrap, ...); raise raises
    const err_lib = vm.newTable(0, 8);
    err_lib.set(vm.gpa, vm.str("meta"), .{ .table = vm.error_meta });
    vm.setGlobal("error", .{ .table = err_lib });
    @import("file.zig").init(vm);
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

/// Renders one argument the way print and concat do: a string as is, a
/// scalar into buf, anything else through toString (which may run a
/// __tostring function; its result is pushed on the stack so that a later
/// call cannot collect it, and the caller pops `pushed` values).
fn renderArg(th: *Thread, v: Value, buf: []u8, pushed: *usize) Error![]const u8 {
    switch (v) {
        .string => |s| return s.bytes(),
        .int, .float, .bool, .null => {
            var w: std.Io.Writer = .fixed(buf);
            vm_mod.format.writeValue(&w, v) catch unreachable;
            return w.buffered();
        },
        else => {
            const s = try th.toString(v);
            try th.ensure(th.top + 1);
            th.push(.{ .string = s });
            pushed.* += 1;
            return s.bytes();
        },
    }
}

/// print(values...): line buffered, so that a server's log and a progress
/// line show up when they are printed, not when the 64 KB buffer fills
fn corePrint(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const n = th.nargs();
    var pushed: usize = 0;
    var newline = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [48]u8 = undefined;
        const piece = try renderArg(th, th.arg(i), &buf, &pushed);
        vm.out().writeAll(piece) catch return vm.raiseKind("io", "write error on stdout", .{});
        if (std.mem.indexOfScalar(u8, piece, '\n') != null) newline = true;
    }
    th.top -= pushed;
    if (newline) vm.flush();
    return .null;
}

const max_pieces = 16;

/// concat(strings...): one allocation for the result; short results are
/// interned like any short string.
fn concatStrings(th: *Thread) Error!Value {
    const vm = th.vm;
    const n = th.nargs();
    if (n > max_pieces) {
        var aw: std.Io.Writer.Allocating = .init(vm.gpa);
        defer aw.deinit();
        try renderArgs(th, 0, &aw);
        return .{ .string = vm.newStringRaw(aw.writer.buffered()) };
    }
    var bufs: [max_pieces][48]u8 = undefined;
    var pieces: [max_pieces][]const u8 = undefined;
    var pushed: usize = 0;
    var total: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pieces[i] = try renderArg(th, th.arg(i), &bufs[i], &pushed);
        total += pieces[i].len;
    }
    var result: *vm_mod.String = undefined;
    if (total <= vm_mod.String.intern_limit) {
        var small: [vm_mod.String.intern_limit]u8 = undefined;
        var at: usize = 0;
        for (pieces[0..n]) |p| {
            @memcpy(small[at .. at + p.len], p);
            at += p.len;
        }
        result = vm.newString(small[0..total]);
    } else {
        result = vm.newStringUninit(total);
        const out = result.mutableBytes();
        var at: usize = 0;
        for (pieces[0..n]) |p| {
            @memcpy(out[at .. at + p.len], p);
            at += p.len;
        }
    }
    th.top -= pushed;
    return .{ .string = result };
}

fn coreArgs(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const t = vm.newTable(vm.args.len, 0);
    for (vm.args) |a| t.append(vm.gpa, vm.str(a));
    return .{ .table = t };
}

fn coreAssert(th: *Thread, args: []Value) Error!Value {
    if (api.arg(args, 0).truthy()) return .null;
    // the message renders like error's: values with __tostring through it
    var aw: std.Io.Writer.Allocating = .init(th.vm.gpa);
    defer aw.deinit();
    try renderArgs(th, 1, &aw);
    const msg = aw.writer.buffered();
    return th.vm.raiseKind("assertion", "{s}", .{if (msg.len == 0) "assertion failed" else msg});
}

/// append(t, v): t[len(t)] = v, the end of the list (v may be null)
fn coreAppend(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    t.append(th.vm.gpa, api.arg(args, 1));
    return .null;
}

/// delete(t, k): takes key k out of t (a list index after it keeps its key:
/// remove shifts, delete does not); the value it held, null when absent
fn coreDelete(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    return t.remove(th.vm.gpa, api.arg(args, 1));
}

/// has(t, k): whether t has key k (which may hold null), without
/// metamethods
fn coreHas(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "table");
    return .{ .bool = t.has(api.arg(args, 1)) };
}

/// same(a, b): whether a and b are the same value: the same table,
/// function, userdata or coroutine (not equal contents, as == has it);
/// other values compare as == does
fn coreSame(th: *Thread, args: []Value) Error!Value {
    _ = th;
    const a = api.arg(args, 0);
    const b = api.arg(args, 1);
    if (a.heapObject()) |oa| {
        if (a != .string) {
            const ob = b.heapObject() orelse return .{ .bool = false };
            return .{ .bool = oa == ob };
        }
    }
    return .{ .bool = a.equals(b) };
}

/// remove(list, i): takes element i out of the list, moving the later ones
/// down, and returns it (delete takes a key out and moves nothing)
fn coreRemove(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "list");
    const i = try api.argInt(th, args, 1, "index");
    return t.removeShifting(th.vm.gpa, i) orelse th.vm.raiseKind("argument", "remove: index {d} is not in the list (length {d})", .{ i, t.arrayLen() });
}

/// A snapshot of the keys of t as an array table (iteration order).
fn keysOf(vm: *VM, t: *const Table) *Table {
    const keys = vm.newTable(t.len(), 0);
    var it = t.iterator();
    while (it.next()) |e| keys.append(vm.gpa, e.key);
    return keys;
}

// The iterators keep {table, position} in the native closure's nvals and
// walk the table as it is (Table.nextLive: no copy of its keys); they
// return stop at the end (null is an element like any other). A for..in
// over keys, values or entries of a table does not call them: forin_prep
// and forin_next walk it in the loop itself (see interp.zig).

fn nextLive(cl: *vm_mod.Closure) ?TableEntry {
    var state: u64 = @intCast(cl.nvals[1].int);
    const e = cl.nvals[0].table.nextLive(&state);
    cl.nvals[1] = .{ .int = @intCast(state) };
    return e;
}

fn keysNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const e = nextLive(th.currentClosure()) orelse return .{ .userdata = th.vm.stop_value };
    return e.key;
}

fn valuesNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const e = nextLive(th.currentClosure()) orelse return .{ .userdata = th.vm.stop_value };
    return e.val;
}

/// {key, value} of an entry (entries)
pub fn entryPair(vm: *VM, e: TableEntry) *Table {
    const pair = vm.newTable(2, 0);
    pair.append(vm.gpa, e.key);
    pair.append(vm.gpa, e.val);
    return pair;
}

fn entriesNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const e = nextLive(th.currentClosure()) orelse return .{ .userdata = th.vm.stop_value };
    return .{ .table = entryPair(th.vm, e) };
}

/// Iterating a buffer (slang/ctypes): nvals are the buffer, the next index
/// and what to give (0 keys, 1 values, 2 entries).
fn bufferNext(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const cl = th.currentClosure();
    const u = cl.nvals[0].userdata;
    const i: usize = @intCast(cl.nvals[1].int);
    const v = (try ctypes.element(th, u, i)) orelse return .{ .userdata = th.vm.stop_value };
    cl.nvals[1] = .{ .int = @intCast(i + 1) };
    switch (cl.nvals[2].int) {
        0 => return .{ .int = @intCast(i) },
        1 => return v,
        else => {
            const pair = th.vm.newTable(2, 0);
            pair.append(th.vm.gpa, .{ .int = @intCast(i) });
            pair.append(th.vm.gpa, v);
            return .{ .table = pair };
        },
    }
}

/// An iterator over a buffer, or null when v is not one.
fn bufferIterator(th: *Thread, v: Value, what: i64, name: []const u8) ?Value {
    if (ctypes.asBuffer(v) == null) return null;
    return .{ .function = th.vm.newNative(name, bufferNext, &.{ v, .{ .int = 0 }, .{ .int = what } }) };
}

pub fn coreKeys(th: *Thread, args: []Value) Error!Value {
    if (bufferIterator(th, api.arg(args, 0), 0, "keys.next")) |it| return it;
    const t = api.arg(args, 0).asTable() orelse return .null;
    return .{ .function = th.vm.newNative("keys.next", keysNext, &.{ .{ .table = t }, .{ .int = 0 } }) };
}

fn iterTable(th: *Thread, args: []Value, name: []const u8) Error!*Table {
    const a = api.arg(args, 0);
    return switch (a) {
        .null => th.vm.newTable(0, 0),
        .table => |t| t,
        else => th.vm.raiseKind("argument", "{s} expects a table, got {s}", .{ name, a.typeName() }),
    };
}

pub fn coreValues(th: *Thread, args: []Value) Error!Value {
    if (bufferIterator(th, api.arg(args, 0), 1, "values.next")) |it| return it;
    const t = try iterTable(th, args, "values");
    return .{ .function = th.vm.newNative("values.next", valuesNext, &.{ .{ .table = t }, .{ .int = 0 } }) };
}

pub fn coreEntries(th: *Thread, args: []Value) Error!Value {
    if (bufferIterator(th, api.arg(args, 0), 2, "entries.next")) |it| return it;
    const t = try iterTable(th, args, "entries");
    return .{ .function = th.vm.newNative("entries.next", entriesNext, &.{ .{ .table = t }, .{ .int = 0 } }) };
}

fn coreConcat(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    switch (api.arg(args, 0)) {
        .string => return concatStrings(th),
        .table => {
            const out = vm.newTable(0, 0);
            for (args, 0..) |a, i| {
                const t = a.asTable() orelse return vm.raiseKind("argument", "concat: argument {d} is not a table", .{i});
                out.addAll(vm.gpa, t);
            }
            return .{ .table = out };
        },
        else => return vm.raiseKind("argument", "concat requires a table or string", .{}),
    }
}

/// raise(value): raises value: an error table (one caught keeps its
/// original location and stack), another table, or any other value (it
/// becomes {message}).
fn coreRaise(th: *Thread, args: []Value) Error!Value {
    th.vm.setErrorFromValue(api.arg(args, 0));
    return error.Slang;
}

fn coreLen(th: *Thread, args: []Value) Error!Value {
    return th.len(api.arg(args, 0));
}

/// count(t): the number of entries of a table, its list and named keys
fn coreCount(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "t");
    return .{ .int = @intCast(t.len()) };
}

fn coreType(th: *Thread, args: []Value) Error!Value {
    return th.typeOf(api.arg(args, 0));
}

/// raw_type(v): the type of v without its metatable's __type: "table"
/// for a table of any class, "userdata" for any userdata
fn coreRawType(th: *Thread, args: []Value) Error!Value {
    return th.vm.str(api.arg(args, 0).typeName());
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
            // a string that is not a number gives null (a lookup that
            // commonly fails, not an error)
            const n = parseIntStrict(body, base) orelse return .null;
            return .{ .int = if (neg) 0 -% n else n };
        },
        else => return th.vm.raiseKind("argument", "to_int requires a number or a string, got {s}", .{a.typeName()}),
    }
}

/// to_float(v): ints as doubles, doubles as they are, strings parsed.
fn coreToFloat(th: *Thread, args: []Value) Error!Value {
    const a = api.arg(args, 0);
    switch (a) {
        .int => |i| return .{ .float = @floatFromInt(i) },
        .float => return a,
        .string => |s| {
            const str = std.mem.trim(u8, s.bytes(), " \t\r\n");
            const f = std.fmt.parseFloat(f64, str) catch return .null;
            return .{ .float = f };
        },
        else => return th.vm.raiseKind("argument", "to_float requires a number or a string, got {s}", .{a.typeName()}),
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
