const std = @import("std");
const root = @import("../vm.zig");
const Proto = root.Proto;
const Writer = std.Io.Writer;

/// Opcodes. The encoding is the one of the Dart implementation:
///
///   31       23       14       6     0
///   |b=9bits |c=9bits |a=8bits |op=6|
///   |    bx=18bits    |a=8bits |op=6|   sbx = bx - 0x1FFFF
///   |    ax=26bits             |op=6|
pub const Op = enum(u6) {
    load_constant = 0, // push K[bx]
    load_bool, // push bool(b); if c: pc++
    load_closure, // push closure(children[ax])
    add,
    sub,
    mul,
    div,
    mod,
    neg,
    not,
    eq,
    lt,
    leq,
    move, // stack[sbx] = pop()
    push, // push stack[sbx]
    pop, // keep top a, drop bx beneath
    @"return", // return top
    new_table, // push {} (b array hint, c hash hint)
    set_table, // t[k] = v (pops 3)
    get_table, // push t[k] (pops 2)
    set_upvalue, // upvals[ax] = pop()
    get_upvalue, // push upvals[ax]
    close_upvalues, // close upvalues >= ax
    @"test", // if truthy(top) != c: pc++ ; pop
    jump, // pc += sbx
    call, // call with bx args
    type, // replace top with its type
    pow, // a ^ b
    _,

    pub fn name(op: Op) []const u8 {
        return switch (op) {
            .load_constant => "loadConstant",
            .load_bool => "loadBool",
            .load_closure => "loadClosure",
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "mod",
            .neg => "neg",
            .not => "not",
            .eq => "eq",
            .lt => "lt",
            .leq => "leq",
            .move => "move",
            .push => "push",
            .pop => "pop",
            .@"return" => "returnOp",
            .new_table => "newTable",
            .set_table => "setTable",
            .get_table => "getTable",
            .set_upvalue => "setUpvalue",
            .get_upvalue => "getUpvalue",
            .close_upvalues => "closeUpvalues",
            .@"test" => "test",
            .jump => "jump",
            .call => "call",
            .type => "type",
            .pow => "pow",
            _ => "op?",
        };
    }

    pub fn symbol(op: Op) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .pow => "^",
            else => op.name(),
        };
    }
};

const Mode = enum { abc, abx, asbx, ax, none };

fn mode(op: Op) Mode {
    return switch (op) {
        .load_constant, .pop, .call => .abx,
        .load_bool, .new_table, .@"test" => .abc,
        .load_closure, .set_upvalue, .get_upvalue, .close_upvalues => .ax,
        .move, .push, .jump => .asbx,
        else => .none,
    };
}

pub inline fn opOf(ins: u32) Op {
    return @enumFromInt(@as(u6, @truncate(ins)));
}
pub inline fn argA(ins: u32) u32 {
    return (ins >> 6) & 0xFF;
}
pub inline fn argB(ins: u32) u32 {
    return (ins >> 23) & 0x1FF;
}
pub inline fn argC(ins: u32) u32 {
    return (ins >> 14) & 0x1FF;
}
pub inline fn argBx(ins: u32) u32 {
    return ins >> 14;
}
pub inline fn argSBx(ins: u32) i32 {
    return @as(i32, @intCast(ins >> 14)) - 0x1FFFF;
}
pub inline fn argAx(ins: u32) u32 {
    return ins >> 6;
}

/// Renders one instruction.
pub fn writeInstruction(w: *Writer, ins: u32) Writer.Error!void {
    const op = opOf(ins);
    const name = op.name();
    switch (mode(op)) {
        .abc => try w.print("{s} A={d} B={d} C={d}", .{ name, argA(ins), argB(ins), argC(ins) }),
        .abx => try w.print("{s} A={d} Bx={d}", .{ name, argA(ins), argBx(ins) }),
        .asbx => try w.print("{s} A={d} sBx={d}", .{ name, argA(ins), argSBx(ins) }),
        .ax => try w.print("{s} Ax={d}", .{ name, argAx(ins) }),
        .none => try w.writeAll(name),
    }
}

/// Renders a prototype and its children.
pub fn disassemble(w: *Writer, p: *const Proto) Writer.Error!void {
    try disasmProto(w, p, "");
}

fn disasmProto(w: *Writer, p: *const Proto, indent: []const u8) Writer.Error!void {
    try w.print("{s}function (nargs={d} vararg={} maxstack={d})\n", .{ indent, p.nargs, p.is_vararg, p.max_stack });
    try w.print("{s}Instructions:\n", .{indent});
    for (p.code, 0..) |ins, i| {
        try w.print("{s}  {d:4}: ", .{ indent, i });
        try writeInstruction(w, ins);
        for (p.locs) |l| {
            if (l.first_pc == i) {
                try w.print("  {s}:{d}:{d}", .{ l.origin.bytes(), l.line, l.column });
                break;
            }
        }
        try w.writeByte('\n');
    }
    if (p.consts.len > 0) {
        try w.print("{s}Constants:\n", .{indent});
        for (p.consts, 0..) |c, i| {
            if (c == .string) {
                try w.print("{s}  {d}: ", .{ indent, i });
                try writeQuoted(w, c.string.bytes());
                try w.writeByte('\n');
            } else {
                try w.print("{s}  {d}: ", .{ indent, i });
                try root.format.writeValue(w, c);
                try w.writeByte('\n');
            }
        }
    }
    if (p.upvals.len > 0) {
        try w.print("{s}Upvalues:\n", .{indent});
        for (p.upvals, 0..) |u, i| {
            try w.print("{s}  {d}: {s} index={d} local={}\n", .{ indent, i, u.name.bytes(), u.index, u.is_local });
        }
    }
    if (p.children.len > 0) {
        try w.print("{s}Children:\n", .{indent});
        var buf: [256]u8 = undefined;
        const sub = std.fmt.bufPrint(&buf, "{s}    ", .{indent}) catch indent;
        for (p.children, 0..) |c, i| {
            try w.print("{s}  {d}:\n", .{ indent, i });
            try disasmProto(w, c, sub);
        }
    }
}

/// Go %q style quoting (enough for the characters that occur in constants).
fn writeQuoted(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20 or c == 0x7f) {
                    try w.print("\\x{x:0>2}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
