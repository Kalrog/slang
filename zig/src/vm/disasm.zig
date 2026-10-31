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
    band, // a & b
    bor, // a | b
    bxor, // a ~ b
    shl, // a << b
    shr, // a >> b (arithmetic)
    bnot, // ~a
    call_spread, // call with bx fixed args followed by a list of the rest
    try_begin, // push a handler: on an error, pc += sbx, close upvalues >= a
    try_end, // pop the innermost handler
    throw, // raise pop()
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
            .band => "band",
            .bor => "bor",
            .bxor => "bxor",
            .shl => "shl",
            .shr => "shr",
            .bnot => "bnot",
            .call_spread => "callSpread",
            .try_begin => "tryBegin",
            .try_end => "tryEnd",
            .throw => "throw",
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
            .band => "&",
            .bor => "|",
            .bxor, .bnot => "~",
            .shl => "<<",
            .shr => ">>",
            else => op.name(),
        };
    }
};

const Mode = enum { abc, abx, asbx, ax, none };

fn mode(op: Op) Mode {
    return switch (op) {
        .load_constant, .pop, .call, .call_spread => .abx,
        .load_bool, .new_table, .@"test" => .abc,
        .load_closure, .set_upvalue, .get_upvalue, .close_upvalues => .ax,
        .move, .push, .jump, .try_begin => .asbx,
        else => .none,
    };
}

pub inline fn opOf(ins: u32) Op {
    return @fromBackingInt(@intCast(@as(u6, @truncate(ins))));
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

/// What an instruction refers to, for the reader: the constant loaded, the
/// upvalue's name, the field a getTable reads, a jump's target, a test's
/// sense, a closure's shape.
fn annotate(w: *Writer, p: *const Proto, pc: usize, ins: u32) Writer.Error!void {
    switch (opOf(ins)) {
        .load_constant => {
            const idx = argBx(ins);
            if (idx < p.consts.len) {
                const c = p.consts[idx];
                if (c == .string) {
                    const b = c.string.bytes();
                    if (b.len > 40) {
                        try writeQuoted(w, b[0..40]);
                        try w.print("... ({d} bytes)", .{b.len});
                    } else {
                        try writeQuoted(w, b);
                    }
                } else {
                    try root.format.writeValue(w, c);
                }
            }
        },
        .load_bool => {
            try w.writeAll(if (argB(ins) != 0) "true" else "false");
            if (argC(ins) != 0) try w.writeAll(", skip next");
        },
        .load_closure => {
            const idx = argAx(ins);
            if (idx < p.children.len) {
                const c = p.children[idx];
                try w.print("function #{d} (nargs={d}{s})", .{ idx, c.nargs, if (c.is_vararg) " vararg" else "" });
            }
        },
        .get_upvalue, .set_upvalue => {
            const idx = argAx(ins);
            if (idx < p.upvals.len) try w.writeAll(p.upvals[idx].name.bytes());
        },
        .get_table => {
            // t.name: the key was loaded just before
            if (pc > 0 and opOf(p.code[pc - 1]) == .load_constant) {
                const idx = argBx(p.code[pc - 1]);
                if (idx < p.consts.len and p.consts[idx] == .string) {
                    try w.print(".{s}", .{p.consts[idx].string.bytes()});
                }
            }
        },
        .jump => try w.print("-> {d}", .{@as(i64, @intCast(pc)) + 1 + argSBx(ins)}),
        .try_begin => try w.print("handler -> {d}, close from register {d}", .{ @as(i64, @intCast(pc)) + 1 + argSBx(ins), argA(ins) }),
        .@"test" => try w.writeAll(if (argC(ins) != 0) "skip next when false" else "skip next when true"),
        .push, .move => {
            const sbx = argSBx(ins);
            if (sbx < 0) try w.print("top{d}", .{sbx}) else try w.print("register {d}", .{sbx});
        },
        .pop => try w.print("keep {d}, drop {d}", .{ argA(ins), argBx(ins) }),
        .new_table => try w.print("array {d}, hash {d}", .{ argB(ins), argC(ins) }),
        .call => try w.print("{d} arg{s}", .{ argBx(ins), if (argBx(ins) == 1) "" else "s" }),
        .call_spread => try w.print("{d} fixed args and a list", .{argBx(ins)}),
        .close_upvalues => try w.print("from register {d}", .{argAx(ins)}),
        else => {},
    }
}

fn disasmProto(w: *Writer, p: *const Proto, indent: []const u8) Writer.Error!void {
    try w.print("{s}function (nargs={d} vararg={} maxstack={d})\n", .{ indent, p.nargs, p.is_vararg, p.max_stack });
    try w.print("{s}Instructions:\n", .{indent});
    for (p.code, 0..) |ins, i| {
        // the instruction, padded, then `; annotation`, then the location
        var ibuf: [64]u8 = undefined;
        var iw: Writer = .fixed(&ibuf);
        writeInstruction(&iw, ins) catch {};
        var abuf: [128]u8 = undefined;
        var aw: Writer = .fixed(&abuf);
        annotate(&aw, p, i, ins) catch {};
        var loc: ?*const @import("object.zig").LocInfo = null;
        for (p.locs) |*l| {
            if (l.first_pc == i) {
                loc = l;
                break;
            }
        }
        const ann = aw.buffered();
        if (loc) |l| {
            try w.print("{s}  {d:4}: {s:<30}", .{ indent, i, iw.buffered() });
            if (ann.len > 0) try w.print(" ; {s:<28}", .{ann}) else try w.print("{s:<31}", .{""});
            try w.print("  {s}:{d}:{d}", .{ l.origin.bytes(), l.line, l.column });
        } else if (ann.len > 0) {
            try w.print("{s}  {d:4}: {s:<30} ; {s}", .{ indent, i, iw.buffered(), ann });
        } else {
            try w.print("{s}  {d:4}: {s}", .{ indent, i, iw.buffered() });
        }
        try w.writeByte('\n');
    }
    if (p.locals.len > 0) {
        try w.print("{s}Locals:\n", .{indent});
        for (p.locals) |l| {
            try w.print("{s}  r{d} {s} pc {d}..{d}\n", .{ indent, l.reg, l.name.bytes(), l.start_pc, l.end_pc });
        }
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
