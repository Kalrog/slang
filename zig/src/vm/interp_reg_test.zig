//! The register loop (interp_reg.zig) on prototypes assembled by hand: the
//! compiler does not emit the register ISA yet (plans/PLAN_REGISTER.md,
//! phase 2).

const std = @import("std");
const root = @import("../vm.zig");
const VM = root.VM;
const Value = root.Value;
const Proto = root.Proto;
const Thread = root.Thread;
const object = @import("object.zig");
const ops = @import("ops.zig");
const d = @import("disasm.zig");
const corelib = @import("../stdlib/core.zig");
const oom = root.oom;

const abc = ops.abc;
const abx = ops.abx;
const asbx = ops.asbx;

fn newVM() *VM {
    return VM.create(std.testing.allocator, std.testing.io, null);
}

const Spec = struct {
    code: []const u32,
    consts: []const Value = &.{},
    regs: u32,
    nargs: u32 = 0,
    children: []const *Proto = &.{},
    upvals: []const object.UpvalDesc = &.{},
    isa: object.Isa = .register,
};

fn proto(vm: *VM, s: Spec) *Proto {
    const p = vm.newProto();
    p.isa = s.isa;
    p.max_stack = s.regs;
    p.nargs = s.nargs;
    p.code = vm.gpa.dupe(u32, s.code) catch oom();
    p.consts = vm.gpa.dupe(Value, s.consts) catch oom();
    p.children = vm.gpa.dupe(*Proto, s.children) catch oom();
    p.upvals = vm.gpa.dupe(object.UpvalDesc, s.upvals) catch oom();
    if (s.isa == .stack) p.temps = d.maxTemps(vm.gpa, p.code);
    return p;
}

fn run(vm: *VM, p: *Proto, args: []const Value) !Value {
    return vm.call(.{ .function = vm.load(p) }, args);
}

/// A stack-ISA instruction (disasm.zig's encoding).
fn stackIns(op: d.Op, a: u32, bx: u32) u32 {
    return @backingInt(op) | a << 6 | bx << 14;
}

test "register arithmetic, constants and comparisons" {
    const vm = newVM();
    defer vm.destroy();
    // (a, b) => (a + b) * 2 - b, then 2 when that is >= 10, else 1
    const p = proto(vm, .{
        .regs = 4,
        .nargs = 2,
        .consts = &.{ .{ .int = 2 }, .{ .int = 10 } },
        .code = &.{
            abc(.add, 2, 0, 1, false),
            abc(.mul, 2, 2, 0, true),
            abc(.sub, 2, 2, 1, false),
            abc(.ge, 0, 2, 1, true), // skip the jump when >= 10
            asbx(.jump, 0, 2),
            asbx(.load_int, 3, 2),
            abc(.@"return", 3, 0, 0, false),
            asbx(.load_int, 3, 1),
            abc(.@"return", 3, 0, 0, false),
        },
    });
    try std.testing.expectEqual(@as(i64, 2), (try run(vm, p, &.{ .{ .int = 3 }, .{ .int = 4 } })).int);
    try std.testing.expectEqual(@as(i64, 1), (try run(vm, p, &.{ .{ .int = 1 }, .{ .int = 2 } })).int);
    // floats and mixed numbers take the same path
    try std.testing.expectEqual(@as(i64, 2), (try run(vm, p, &.{ .{ .float = 3.5 }, .{ .int = 4 } })).int);
}

test "register calls: slang, native, upvalues, the other ISA" {
    const vm = newVM();
    defer vm.destroy();
    // a closure over the caller's register 0, counting it up
    const counter = proto(vm, .{ .regs = 1, .consts = &.{.{ .int = 1 }}, .upvals = &.{.{ .name = vm.newString("n"), .index = 0, .is_local = true }}, .code = &.{
        abc(.get_upval, 0, 0, 0, false),
        abc(.add, 0, 0, 0, true),
        abc(.set_upval, 0, 0, 0, false),
        abc(.@"return", 0, 0, 0, false),
    } });
    const main = proto(vm, .{
        .regs = 3,
        .children = &.{counter},
        .code = &.{
            asbx(.load_int, 0, 10),
            abx(.closure, 1, 0),
            abc(.move, 2, 1, 0, false),
            abc(.call, 2, 0, 0, false),
            abc(.move, 2, 1, 0, false),
            abc(.call, 2, 0, 0, false), // 12, and so is register 0
            abc(.add, 2, 2, 0, false),
            abc(.@"return", 2, 0, 0, false),
        },
    });
    try std.testing.expectEqual(@as(i64, 24), (try run(vm, main, &.{})).int);

    // a native, its result in the call's register
    const twice = struct {
        fn f(_: *Thread, args: []Value) root.Error!Value {
            return .{ .int = args[0].int * 2 };
        }
    }.f;
    const callNative = proto(vm, .{ .regs = 4, .nargs = 2, .code = &.{
        abc(.move, 2, 0, 0, false),
        abc(.move, 3, 1, 0, false),
        abc(.call, 2, 1, 0, false),
        abc(.@"return", 2, 0, 0, false),
    } });
    try std.testing.expectEqual(@as(i64, 42), (try run(vm, callNative, &.{ vm.nativeValue("twice", twice), .{ .int = 21 } })).int);

    // register code calling stack code calling register code:
    // (n) => child(n) - 1, child = (x) => g(x) + 1, g = (y) => y * 3
    const g = proto(vm, .{ .regs = 2, .nargs = 1, .consts = &.{.{ .int = 3 }}, .code = &.{
        abc(.mul, 1, 0, 0, true),
        abc(.@"return", 1, 0, 0, false),
    } });
    const child = proto(vm, .{ .isa = .stack, .regs = 1, .nargs = 1, .children = &.{g}, .consts = &.{.{ .int = 1 }}, .code = &.{
        @backingInt(d.Op.load_closure),
        stackIns(.push, 0, 0x1FFFF),
        stackIns(.call, 0, 1),
        stackIns(.load_constant, 0, 0),
        @backingInt(d.Op.add),
        @backingInt(d.Op.@"return"),
    } });
    const mixed = proto(vm, .{ .regs = 4, .nargs = 1, .children = &.{child}, .consts = &.{.{ .int = 1 }}, .code = &.{
        abx(.closure, 1, 0),
        abc(.move, 2, 1, 0, false),
        abc(.move, 3, 0, 0, false),
        abc(.call, 2, 1, 0, false),
        abc(.sub, 2, 2, 0, true),
        abc(.@"return", 2, 0, 0, false),
    } });
    try std.testing.expectEqual(@as(i64, 15), (try run(vm, mixed, &.{.{ .int = 5 }})).int);
}

test "register loops: for_loop and for..in over a table" {
    const vm = newVM();
    defer vm.destroy();
    // (n) => the sum of 0, 1, ... while i < n
    const sum = proto(vm, .{
        .regs = 3,
        .nargs = 1,
        .consts = &.{.{ .int = 1 }},
        .code = &.{
            asbx(.load_int, 1, 0),
            asbx(.load_int, 2, 0),
            abc(.lt, 0, 2, 0, false), // the condition, two before the body
            asbx(.jump, 0, 3),
            abc(.add, 1, 1, 2, false), // the body
            abc(.for_loop, 2, 0, 0, false),
            asbx(.jump, ops.for_flags.step_k, -3),
            abc(.@"return", 1, 0, 0, false),
        },
    });
    try std.testing.expectEqual(@as(i64, 45), (try run(vm, sum, &.{.{ .int = 10 }})).int);
    // a float limit: the full comparison
    try std.testing.expectEqual(@as(i64, 55), (try run(vm, sum, &.{.{ .float = 10.5 }})).int);
    try std.testing.expectEqual(@as(i64, 0), (try run(vm, sum, &.{.{ .int = 0 }})).int);

    // (f, t) => the sum of the elements for..in f(t) walks
    const walk = proto(vm, .{
        .regs = 6,
        .nargs = 2,
        .code = &.{
            asbx(.load_int, 2, 0),
            abc(.move, 3, 0, 0, false),
            abc(.move, 4, 1, 0, false),
            abc(.forin_prep, 3, 0, 0, false),
            abc(.forin_next, 3, 0, 0, false),
            asbx(.jump, 0, 5), // the end
            asbx(.jump, 0, 2), // the pattern
            abc(.return_null, 0, 0, 0, false), // (an iterator function's call)
            abc(.return_null, 0, 0, 0, false),
            abc(.add, 2, 2, 5, false),
            asbx(.jump, 0, -7), // a backward jump: a safe point
            abc(.@"return", 2, 0, 0, false),
        },
    });
    const t = vm.newTable(3, 0);
    for (0..3) |i| t.set(vm.gpa, .{ .int = @intCast(i) }, .{ .int = @intCast(i + 1) });
    const values: Value = .{ .function = vm.newNative("values", corelib.coreValues, &.{}) };
    try std.testing.expectEqual(@as(i64, 6), (try run(vm, walk, &.{ values, .{ .table = t } })).int);

    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.disassemble(&w, walk);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "forinNext 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "registers=6") != null);
}

test "register try: a throw and an error from a call land in the handler's register" {
    const vm = newVM();
    defer vm.destroy();
    // (x) => try { throw x } catch e { return e }
    const catcher = proto(vm, .{ .regs = 2, .nargs = 1, .code = &.{
        asbx(.try_begin, 1, 3),
        abc(.throw, 0, 0, 0, false),
        abc(.try_end, 0, 0, 0, false),
        abc(.return_null, 0, 0, 0, false),
        abc(.@"return", 1, 0, 0, false),
    } });
    const err = vm.newTable(0, 1);
    const caught = try run(vm, catcher, &.{.{ .table = err }});
    try std.testing.expect(caught == .table and caught.table == err);

    // (x) => try { x() } catch e { return e.message }: calling null raises
    const calls = proto(vm, .{ .regs = 3, .nargs = 1, .consts = &.{.{ .string = vm.newString("message") }}, .code = &.{
        asbx(.try_begin, 1, 4),
        abc(.move, 2, 0, 0, false),
        abc(.call, 2, 0, 0, false),
        abc(.try_end, 0, 0, 0, false),
        abc(.return_null, 0, 0, 0, false),
        abc(.get_field, 1, 1, 0, false),
        abc(.@"return", 1, 0, 0, false),
    } });
    const msg = try run(vm, calls, &.{.null});
    try std.testing.expect(msg == .string);
    try std.testing.expect(std.mem.indexOf(u8, msg.string.bytes(), "call a null value") != null);
}

test "register fields: getters, methods, stores, quickened" {
    const vm = newVM();
    defer vm.destroy();
    const getter = proto(vm, .{ .regs = 2, .nargs = 1, .code = &.{
        asbx(.load_int, 1, 7),
        abc(.@"return", 1, 0, 0, false),
    } });
    const method = proto(vm, .{ .regs = 2, .nargs = 1, .code = &.{
        asbx(.load_int, 1, 100),
        abc(.@"return", 1, 0, 0, false),
    } });
    // (obj) => obj.y = 5; obj.x + obj:m() + obj.x + obj.y
    const main = proto(vm, .{ .regs = 4, .nargs = 1, .consts = &.{
        .{ .string = vm.newString("x") },
        .{ .string = vm.newString("m") },
        .{ .string = vm.newString("y") },
        .{ .int = 5 },
    }, .code = &.{
        abc(.set_field, 0, 2, 3, true),
        abc(.get_field, 1, 0, 0, false),
        abc(.self, 2, 0, 1, true),
        abc(.call, 2, 1, 0, false),
        abc(.add, 1, 1, 2, false),
        abc(.get_field, 2, 0, 0, false),
        abc(.add, 1, 1, 2, false),
        abc(.get_field, 2, 0, 2, false),
        abc(.add, 1, 1, 2, false),
        abc(.@"return", 1, 0, 0, false),
    } });
    const index = vm.newTable(0, 1);
    index.set(vm.gpa, vm.str("m"), .{ .function = vm.load(method) });
    const gets = vm.newTable(0, 1);
    gets.set(vm.gpa, vm.str("x"), .{ .function = vm.load(getter) });
    const meta = vm.newTable(0, 2);
    meta.set(vm.gpa, vm.str("__index"), .{ .table = index });
    meta.set(vm.gpa, vm.str("__get"), .{ .table = gets });
    const obj = vm.newTable(0, 1);
    obj.set(vm.gpa, vm.str("y"), .{ .int = 0 });
    obj.setMetatable(vm.gpa, meta);
    for (0..3) |_| {
        try std.testing.expectEqual(@as(i64, 119), (try run(vm, main, &.{.{ .table = obj }})).int);
    }
    // the loads and the store are quickened; listings show them as compiled
    try std.testing.expectEqual(ops.Op.set_field_q, ops.opOf(main.code[0]));
    try std.testing.expectEqual(ops.Op.get_field_q, ops.opOf(main.code[1]));
    try std.testing.expectEqual(ops.Op.self_q, ops.opOf(main.code[2]));
    try std.testing.expectEqual(ops.Op.get_field, ops.opOf(main.original(main.code[1])));
    try std.testing.expectEqual(main.code.len, 10);
    const bytes = root.slb.encode(vm.gpa, main, false);
    defer vm.gpa.free(bytes);
    try std.testing.expectEqual(root.slb.version_register, bytes[5]);
    const back = try root.slb.decode(vm, bytes);
    try std.testing.expectEqual(object.Isa.register, back.isa);
    try std.testing.expectEqual(ops.Op.get_field, ops.opOf(back.code[1]));
}
