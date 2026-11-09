//! vec3: the vector benchmark's native library (bench/vectors), written in
//! Zig against slang.h. 3D vectors of doubles in the styles a native
//! library could offer:
//!
//! - a userdata type (`vec3.new(x, y, z)`): functions that return a new
//!   vector (`vec3.add(a, b)`), work in place (`vec3.axpy(p, v, dt)`),
//!   methods (`p:axpy(v, dt)`), operators (`a + b * dt`) and fields
//!   (`v.x`, properties through __get);
//! - functions on slang tables {x, y, z} (`vec3.tadd`, `vec3.taxpy`,
//!   `vec3.tdot`): fields read and written through the API;
//! - a batch over buffers of doubles (`vec3.step(p, v, dt)`: x, y, z per
//!   element, p += v * dt).
//!
//! Built by `zig build bench-libs` into build/bench (not installed).

const c = @import("slang");

const V = extern struct { x: f64, y: f64, z: f64 };
const tname = "vec3";

fn push(S: ?*c.slang_State, x: f64, y: f64, z: f64) void {
    const p: *V = @ptrCast(@alignCast(c.slang_newuserdata(S, @sizeOf(V), tname, null)));
    p.* = .{ .x = x, .y = y, .z = z };
}

fn check(S: ?*c.slang_State, idx: c_int) ?*V {
    const p = c.slang_checkudata(S, idx, tname) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn new(S: ?*c.slang_State) callconv(.c) c_int {
    const x = c.slang_optnumber(S, 1, 0);
    const y = c.slang_optnumber(S, 2, 0);
    const z = c.slang_optnumber(S, 3, 0);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    push(S, x, y, z);
    return 1;
}

fn add(S: ?*c.slang_State) callconv(.c) c_int {
    const a = check(S, 1) orelse return c.SLANG_ERROR;
    const b = check(S, 2) orelse return c.SLANG_ERROR;
    push(S, a.x + b.x, a.y + b.y, a.z + b.z);
    return 1;
}

/// a * k or k * a
fn mul(S: ?*c.slang_State) callconv(.c) c_int {
    const vi: c_int = if (c.slang_isuserdata(S, 1)) 1 else 2;
    const a = check(S, vi) orelse return c.SLANG_ERROR;
    const k = c.slang_checknumber(S, 3 - vi);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    push(S, a.x * k, a.y * k, a.z * k);
    return 1;
}

/// p += v * dt, in place
fn axpy(S: ?*c.slang_State) callconv(.c) c_int {
    const p = check(S, 1) orelse return c.SLANG_ERROR;
    const v = check(S, 2) orelse return c.SLANG_ERROR;
    const dt = c.slang_checknumber(S, 3);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    p.x += v.x * dt;
    p.y += v.y * dt;
    p.z += v.z * dt;
    return 0;
}

fn dot(S: ?*c.slang_State) callconv(.c) c_int {
    const a = check(S, 1) orelse return c.SLANG_ERROR;
    const b = check(S, 2) orelse return c.SLANG_ERROR;
    c.slang_pushdouble(S, a.x * b.x + a.y * b.y + a.z * b.z);
    return 1;
}

fn getX(S: ?*c.slang_State) callconv(.c) c_int {
    const a = check(S, 1) orelse return c.SLANG_ERROR;
    c.slang_pushdouble(S, a.x);
    return 1;
}

fn getY(S: ?*c.slang_State) callconv(.c) c_int {
    const a = check(S, 1) orelse return c.SLANG_ERROR;
    c.slang_pushdouble(S, a.y);
    return 1;
}

fn getZ(S: ?*c.slang_State) callconv(.c) c_int {
    const a = check(S, 1) orelse return c.SLANG_ERROR;
    c.slang_pushdouble(S, a.z);
    return 1;
}

// ---- on slang tables {x, y, z}

fn field(S: ?*c.slang_State, idx: c_int, name: [*:0]const u8) f64 {
    _ = c.slang_getfield(S, idx, name);
    const v = c.slang_todouble(S, -1);
    c.slang_settop(S, -2);
    return v;
}

fn setField(S: ?*c.slang_State, idx: c_int, name: [*:0]const u8, v: f64) void {
    c.slang_pushdouble(S, v);
    _ = c.slang_setfield(S, idx, name);
}

fn tadd(S: ?*c.slang_State) callconv(.c) c_int {
    const x = field(S, 1, "x") + field(S, 2, "x");
    const y = field(S, 1, "y") + field(S, 2, "y");
    const z = field(S, 1, "z") + field(S, 2, "z");
    c.slang_newtable(S);
    setField(S, -2, "x", x);
    setField(S, -2, "y", y);
    setField(S, -2, "z", z);
    return 1;
}

fn taxpy(S: ?*c.slang_State) callconv(.c) c_int {
    const dt = c.slang_checknumber(S, 3);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    setField(S, 1, "x", field(S, 1, "x") + field(S, 2, "x") * dt);
    setField(S, 1, "y", field(S, 1, "y") + field(S, 2, "y") * dt);
    setField(S, 1, "z", field(S, 1, "z") + field(S, 2, "z") * dt);
    return 0;
}

fn tdot(S: ?*c.slang_State) callconv(.c) c_int {
    c.slang_pushdouble(S, field(S, 1, "x") * field(S, 2, "x") + field(S, 1, "y") * field(S, 2, "y") + field(S, 1, "z") * field(S, 2, "z"));
    return 1;
}

// ---- a batch over buffers of doubles (x, y, z per element)

fn step(S: ?*c.slang_State) callconv(.c) c_int {
    var n: usize = 0;
    var m: usize = 0;
    const pp = c.slang_tobuffer(S, 1, &n, null) orelse return c.slang_argerror(S, 1, "buffer expected");
    const vp = c.slang_tobuffer(S, 2, &m, null) orelse return c.slang_argerror(S, 2, "buffer expected");
    const dt = c.slang_checknumber(S, 3);
    if (c.slang_failed(S)) return c.SLANG_ERROR;
    const p: [*]f64 = @ptrCast(@alignCast(pp));
    const v: [*]f64 = @ptrCast(@alignCast(vp));
    for (0..@min(n, m)) |i| p[i] += v[i] * dt;
    return 0;
}

const meta = [_]c.slang_Reg{
    .{ .name = "__add", .func = add },
    .{ .name = "__mul", .func = mul },
    .{ .name = null, .func = null },
};

const methods = [_]c.slang_Reg{
    .{ .name = "add", .func = add },
    .{ .name = "axpy", .func = axpy },
    .{ .name = "dot", .func = dot },
    .{ .name = null, .func = null },
};

const getters = [_]c.slang_Reg{
    .{ .name = "x", .func = getX },
    .{ .name = "y", .func = getY },
    .{ .name = "z", .func = getZ },
    .{ .name = null, .func = null },
};

const funcs = [_]c.slang_Reg{
    .{ .name = "new", .func = new },
    .{ .name = "add", .func = add },
    .{ .name = "axpy", .func = axpy },
    .{ .name = "dot", .func = dot },
    .{ .name = "tadd", .func = tadd },
    .{ .name = "taxpy", .func = taxpy },
    .{ .name = "tdot", .func = tdot },
    .{ .name = "step", .func = step },
    .{ .name = null, .func = null },
};

export fn slang_ext_version_vec3() c_int {
    return c.SLANG_API_VERSION;
}

export fn slang_open_vec3(S: ?*c.slang_State) c_int {
    c.slang_newmodule(S, &meta);
    c.slang_newmodule(S, &methods);
    _ = c.slang_setfield(S, -2, "__index");
    c.slang_newmodule(S, &getters);
    _ = c.slang_setfield(S, -2, "__get");
    c.slang_pushstring(S, tname);
    _ = c.slang_setfield(S, -2, "__type");
    c.slang_settypemeta(S, tname);
    c.slang_newmodule(S, &funcs);
    return 1;
}
