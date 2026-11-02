//! vec: an example native extension written in Zig against slang.h. A 2D
//! vector userdata with operator metamethods, so `a + b`, `a * 2`, `a == b`
//! and `string(a)` work on vectors.
//!
//! Zig extensions use the same C ABI as C ones: the header is imported
//! (translated by the build, see zig/build.zig) and the entry point is
//! exported under the name the loader expects.

const std = @import("std");
const c = @import("slang");

const Vec = extern struct { x: f64, y: f64 };

const tname = "vec";

fn pushVec(S: ?*c.slang_State, x: f64, y: f64) void {
    const p: *Vec = @ptrCast(@alignCast(c.slang_newuserdata(S, @sizeOf(Vec), tname, null)));
    p.* = .{ .x = x, .y = y };
}

fn checkVec(S: ?*c.slang_State, idx: c_int) ?*Vec {
    const p = c.slang_checkudata(S, idx, tname) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn new(S: ?*c.slang_State) callconv(.c) c_int {
    const x = c.slang_optnumber(S, 1, 0);
    const y = c.slang_optnumber(S, 2, 0);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    pushVec(S, x, y);
    return 1;
}

fn add(S: ?*c.slang_State) callconv(.c) c_int {
    const a = checkVec(S, 1) orelse return c.SLANG_ERROR;
    const b = checkVec(S, 2) orelse return c.SLANG_ERROR;
    pushVec(S, a.x + b.x, a.y + b.y);
    return 1;
}

fn mul(S: ?*c.slang_State) callconv(.c) c_int {
    // either operand may be the number
    if (c.slang_isuserdata(S, 1)) {
        const a = checkVec(S, 1) orelse return c.SLANG_ERROR;
        const k = c.slang_checknumber(S, 2);
        if (c.slang_failed(S)) return c.SLANG_ERROR;
        pushVec(S, a.x * k, a.y * k);
    } else {
        const k = c.slang_checknumber(S, 1);
        const b = checkVec(S, 2) orelse return c.SLANG_ERROR;
        if (c.slang_failed(S)) return c.SLANG_ERROR;
        pushVec(S, b.x * k, b.y * k);
    }
    return 1;
}

fn eq(S: ?*c.slang_State) callconv(.c) c_int {
    const a = checkVec(S, 1) orelse return c.SLANG_ERROR;
    const b = checkVec(S, 2) orelse return c.SLANG_ERROR;
    c.slang_pushbool(S, a.x == b.x and a.y == b.y);
    return 1;
}

fn length(S: ?*c.slang_State) callconv(.c) c_int {
    const a = checkVec(S, 1) orelse return c.SLANG_ERROR;
    c.slang_pushdouble(S, @sqrt(a.x * a.x + a.y * a.y));
    return 1;
}

fn toString(S: ?*c.slang_State) callconv(.c) c_int {
    const a = checkVec(S, 1) orelse return c.SLANG_ERROR;
    c.slang_pushfstring(S, "vec(%g, %g)", a.x, a.y);
    return 1;
}

/// Field access: v.x, v.y and the methods.
fn index(S: ?*c.slang_State) callconv(.c) c_int {
    const a = checkVec(S, 1) orelse return c.SLANG_ERROR;
    const key = c.slang_tolstring(S, 2, null) orelse return 0;
    const k = std.mem.span(key);
    if (std.mem.eql(u8, k, "x")) {
        c.slang_pushdouble(S, a.x);
    } else if (std.mem.eql(u8, k, "y")) {
        c.slang_pushdouble(S, a.y);
    } else if (std.mem.eql(u8, k, "length")) {
        c.slang_pushcfunction(S, length, "length");
    } else {
        return 0;
    }
    return 1;
}

const meta = [_]c.slang_Reg{
    .{ .name = "__add", .func = add },
    .{ .name = "__mul", .func = mul },
    .{ .name = "__eq", .func = eq },
    .{ .name = "__tostring", .func = toString },
    .{ .name = "__index", .func = index },
    .{ .name = null, .func = null },
};

const funcs = [_]c.slang_Reg{
    .{ .name = "new", .func = new },
    .{ .name = "length", .func = length },
    .{ .name = null, .func = null },
};

export fn slang_ext_version_vec() c_int {
    return c.SLANG_API_VERSION;
}

export fn slang_open_vec(S: ?*c.slang_State) c_int {
    c.slang_newmodule(S, &meta);
    c.slang_pushstring(S, "vec");
    _ = c.slang_setfield(S, -2, "__type");
    c.slang_settypemeta(S, tname);
    c.slang_newmodule(S, &funcs);
    return 1;
}
