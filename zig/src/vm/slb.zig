//! The .slb container, version 3 (version 2 has no name and is still read):
//!
//!   magic "SLANG", u8 version
//!   proto := u32 maxStack, u32 nargs, u8 isVarArg, str name ("": none),
//!            u32 nCode, u32[nCode],
//!            u32 nLocs, {u32 firstPC, str origin, u32 line, u32 column}*,
//!            u32 nConsts, {u8 tag, payload}*   (0 int i64, 1 double f64, 2 string, 3 bool u8, 4 null)
//!            u32 nUpvals, {str name, u32 index, u8 isLocal}*,
//!            u32 nChildren, proto*
//!   str := u32 byteLen, bytes (UTF-8)
//!
//! Everything is little endian.

const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const VM = root.VM;
const Value = root.Value;
const Proto = root.Proto;
const object = @import("object.zig");

pub const magic = "SLANG";
pub const version: u8 = 3;

const Tag = enum(u8) { int = 0, double = 1, string = 2, bool = 3, null = 4 };

pub const DecodeError = error{ BadMagic, BadVersion, Truncated, BadCount, BadTag, TooDeep };

pub fn errorMessage(e: DecodeError) []const u8 {
    return switch (e) {
        error.BadMagic => "not a slang bytecode file (bad magic)",
        error.BadVersion => "unsupported bytecode version (want 2 or 3)",
        error.Truncated => "bytecode: unexpected end of data",
        error.BadCount => "bytecode: implausible count",
        error.BadTag => "bytecode: unknown constant tag",
        error.TooDeep => "bytecode: prototype nesting too deep",
    };
}

/// Serialises a prototype. With strip_locs the source locations are omitted.
pub fn encode(gpa: std.mem.Allocator, p: *const Proto, strip_locs: bool) []u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    const out = &w.writer;
    out.writeAll(magic) catch oom();
    out.writeByte(version) catch oom();
    encodeProto(out, p, strip_locs);
    return w.toOwnedSlice() catch oom();
}

fn encodeStr(w: *std.Io.Writer, s: []const u8) void {
    w.writeInt(u32, @intCast(s.len), .little) catch oom();
    w.writeAll(s) catch oom();
}

fn encodeProto(w: *std.Io.Writer, p: *const Proto, strip_locs: bool) void {
    w.writeInt(u32, p.max_stack, .little) catch oom();
    w.writeInt(u32, p.nargs, .little) catch oom();
    w.writeByte(@intFromBool(p.is_vararg)) catch oom();
    encodeStr(w, if (p.name) |n| n.bytes() else "");
    w.writeInt(u32, @intCast(p.code.len), .little) catch oom();
    for (p.code) |c| w.writeInt(u32, c, .little) catch oom();
    if (strip_locs) {
        w.writeInt(u32, 0, .little) catch oom();
    } else {
        w.writeInt(u32, @intCast(p.locs.len), .little) catch oom();
        for (p.locs) |l| {
            w.writeInt(u32, l.first_pc, .little) catch oom();
            encodeStr(w, l.origin.bytes());
            w.writeInt(u32, l.line, .little) catch oom();
            w.writeInt(u32, l.column, .little) catch oom();
        }
    }
    w.writeInt(u32, @intCast(p.consts.len), .little) catch oom();
    for (p.consts) |c| {
        switch (c) {
            .int => |i| {
                w.writeByte(@intFromEnum(Tag.int)) catch oom();
                w.writeInt(i64, i, .little) catch oom();
            },
            .float => |f| {
                w.writeByte(@intFromEnum(Tag.double)) catch oom();
                w.writeInt(u64, @bitCast(f), .little) catch oom();
            },
            .string => |s| {
                w.writeByte(@intFromEnum(Tag.string)) catch oom();
                encodeStr(w, s.bytes());
            },
            .bool => |b| {
                w.writeByte(@intFromEnum(Tag.bool)) catch oom();
                w.writeByte(@intFromBool(b)) catch oom();
            },
            else => w.writeByte(@intFromEnum(Tag.null)) catch oom(),
        }
    }
    w.writeInt(u32, @intCast(p.upvals.len), .little) catch oom();
    for (p.upvals) |u| {
        encodeStr(w, u.name.bytes());
        w.writeInt(u32, u.index, .little) catch oom();
        w.writeByte(@intFromBool(u.is_local)) catch oom();
    }
    w.writeInt(u32, @intCast(p.children.len), .little) catch oom();
    for (p.children) |c| encodeProto(w, c, strip_locs);
}

const Reader = struct {
    vm: *VM,
    buf: []const u8,
    pos: usize = 0,
    version: u8 = version,

    fn take(r: *Reader, n: usize) DecodeError![]const u8 {
        if (r.pos + n > r.buf.len) return error.Truncated;
        const b = r.buf[r.pos .. r.pos + n];
        r.pos += n;
        return b;
    }

    fn u8_(r: *Reader) DecodeError!u8 {
        return (try r.take(1))[0];
    }

    fn u32_(r: *Reader) DecodeError!u32 {
        return std.mem.readInt(u32, (try r.take(4))[0..4], .little);
    }

    fn u64_(r: *Reader) DecodeError!u64 {
        return std.mem.readInt(u64, (try r.take(8))[0..8], .little);
    }

    fn str(r: *Reader) DecodeError!*root.String {
        const n = try r.u32_();
        return r.vm.newString(try r.take(n));
    }

    fn count(r: *Reader) DecodeError!usize {
        const n = try r.u32_();
        if (n > r.buf.len) return error.BadCount;
        return n;
    }

    fn proto(r: *Reader, depth: usize) DecodeError!*Proto {
        if (depth > 200) return error.TooDeep;
        const gpa = r.vm.gpa;
        const p = r.vm.newProto();
        p.max_stack = try r.u32_();
        p.nargs = try r.u32_();
        p.is_vararg = (try r.u8_()) != 0;
        if (r.version >= 3) {
            const name = try r.str();
            if (name.bytes().len > 0) p.name = name;
        }
        const ncode = try r.count();
        p.code = gpa.alloc(u32, ncode) catch oom();
        for (p.code) |*c| c.* = try r.u32_();
        const nlocs = try r.count();
        p.locs = gpa.alloc(object.LocInfo, nlocs) catch oom();
        for (p.locs) |*l| {
            l.first_pc = try r.u32_();
            l.origin = try r.str();
            l.line = try r.u32_();
            l.column = try r.u32_();
        }
        const nconsts = try r.count();
        p.consts = gpa.alloc(Value, nconsts) catch oom();
        for (p.consts) |*c| {
            const tag = try r.u8_();
            c.* = switch (tag) {
                @intFromEnum(Tag.int) => .{ .int = @bitCast(try r.u64_()) },
                @intFromEnum(Tag.double) => .{ .float = @bitCast(try r.u64_()) },
                @intFromEnum(Tag.string) => .{ .string = try r.str() },
                @intFromEnum(Tag.bool) => .{ .bool = (try r.u8_()) != 0 },
                @intFromEnum(Tag.null) => .null,
                else => return error.BadTag,
            };
        }
        const nups = try r.count();
        p.upvals = gpa.alloc(object.UpvalDesc, nups) catch oom();
        for (p.upvals) |*u| {
            u.name = try r.str();
            u.index = try r.u32_();
            u.is_local = (try r.u8_()) != 0;
        }
        const nchildren = try r.count();
        p.children = gpa.alloc(*Proto, nchildren) catch oom();
        // Allocate before filling so a decode error leaves no dangling slots
        // for the collector.
        for (p.children) |*c| c.* = p;
        for (p.children) |*c| c.* = try r.proto(depth + 1);
        return p;
    }
};

/// Parses a .slb v2 container. The prototypes become VM objects.
pub fn decode(vm: *VM, data: []const u8) DecodeError!*Proto {
    var r: Reader = .{ .vm = vm, .buf = data };
    const m = try r.take(magic.len);
    if (!std.mem.eql(u8, m, magic)) return error.BadMagic;
    r.version = try r.u8_();
    if (r.version != 2 and r.version != 3) return error.BadVersion;
    return r.proto(0);
}
