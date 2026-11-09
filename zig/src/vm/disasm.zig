//! Listings of compiled functions (`slang disasm`, vm.disassemble): each
//! instruction (ops.zig renders it), what it refers to, its location, then
//! the locals, constants, upvalues and nested functions.

const std = @import("std");
const root = @import("../vm.zig");
const Proto = root.Proto;
const Writer = std.Io.Writer;
const ops = @import("ops.zig");

/// Renders a prototype and its children.
pub fn disassemble(w: *Writer, p: *const Proto) Writer.Error!void {
    try disasmProto(w, p, "");
}

fn disasmProto(w: *Writer, p: *const Proto, indent: []const u8) Writer.Error!void {
    try w.print("{s}function (nargs={d} vararg={} registers={d})\n", .{ indent, p.nargs, p.is_vararg, p.max_stack });
    try w.print("{s}Instructions:\n", .{indent});
    for (p.code, 0..) |quick, i| {
        // (as compiled: a quickened instruction as it was)
        const ins = p.original(quick);
        // the instruction, padded, then `; annotation`, then the location
        var ibuf: [64]u8 = undefined;
        var iw: Writer = .fixed(&ibuf);
        var abuf: [128]u8 = undefined;
        var aw: Writer = .fixed(&abuf);
        ops.writeInstruction(&iw, ins) catch {};
        ops.annotate(&aw, p, i, ins) catch {};
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
