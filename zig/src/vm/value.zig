const std = @import("std");
const String = @import("string.zig").String;
const Table = @import("table.zig").Table;
const object = @import("object.zig");
const Closure = object.Closure;
const Userdata = object.Userdata;
const Thread = @import("thread.zig").Thread;

/// The dynamic type tag. The order matches the Go VM so that type names and
/// bytecode constants agree.
pub const Kind = enum(u8) {
    null,
    bool,
    int,
    float,
    string,
    table,
    function,
    userdata,
    thread,

    pub fn name(k: Kind) []const u8 {
        return switch (k) {
            .null => "null",
            .bool => "bool",
            .int => "int",
            .float => "double",
            .string => "string",
            .table => "table",
            .function => "function",
            .userdata => "userdata",
            .thread => "thread",
        };
    }
};

/// A slang value: 16 bytes, null/bool/int/double never allocate, the other
/// kinds point at a heap object owned by the VM's collector.
pub const Value = union(Kind) {
    null: void,
    bool: bool,
    int: i64,
    float: f64,
    string: *String,
    table: *Table,
    function: *Closure,
    userdata: *Userdata,
    thread: *Thread,

    pub const nil: Value = .null;
    pub const @"true": Value = .{ .bool = true };
    pub const @"false": Value = .{ .bool = false };

    pub fn fromBool(b: bool) Value {
        return .{ .bool = b };
    }
    pub fn fromInt(i: i64) Value {
        return .{ .int = i };
    }
    pub fn fromFloat(f: f64) Value {
        return .{ .float = f };
    }
    pub fn fromString(s: *String) Value {
        return .{ .string = s };
    }
    pub fn fromTable(t: ?*Table) Value {
        return if (t) |p| .{ .table = p } else .null;
    }
    pub fn fromClosure(c: ?*Closure) Value {
        return if (c) |p| .{ .function = p } else .null;
    }
    pub fn fromUserdata(u: *Userdata) Value {
        return .{ .userdata = u };
    }
    pub fn fromThread(t: *Thread) Value {
        return .{ .thread = t };
    }

    pub fn kind(v: Value) Kind {
        return std.meta.activeTag(v);
    }
    pub fn typeName(v: Value) []const u8 {
        return v.kind().name();
    }
    pub fn isNull(v: Value) bool {
        return v == .null;
    }
    pub fn isNumber(v: Value) bool {
        return v == .int or v == .float;
    }

    /// Everything except null and false counts as true.
    pub fn truthy(v: Value) bool {
        return switch (v) {
            .null => false,
            .bool => |b| b,
            else => true,
        };
    }

    /// An int or double as f64.
    pub fn asNumber(v: Value) f64 {
        return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            else => 0,
        };
    }
    pub fn asInt(v: Value) i64 {
        return switch (v) {
            .int => |i| i,
            else => 0,
        };
    }
    pub fn asTable(v: Value) ?*Table {
        return switch (v) {
            .table => |t| t,
            else => null,
        };
    }
    pub fn asString(v: Value) ?*String {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }
    pub fn asBytes(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s.bytes(),
            else => null,
        };
    }
    pub fn asClosure(v: Value) ?*Closure {
        return switch (v) {
            .function => |c| c,
            else => null,
        };
    }
    pub fn asUserdata(v: Value) ?*Userdata {
        return switch (v) {
            .userdata => |u| u,
            else => null,
        };
    }
    pub fn asThread(v: Value) ?*Thread {
        return switch (v) {
            .thread => |t| t,
            else => null,
        };
    }

    /// The heap object behind the value, if any (for the collector).
    pub fn heapObject(v: Value) ?*object.Object {
        return switch (v) {
            .string => |s| &s.obj,
            .table => |t| &t.obj,
            .function => |c| &c.obj,
            .userdata => |u| &u.obj,
            .thread => |t| &t.obj,
            else => null,
        };
    }

    /// Identity: the same payload (pointer equality for objects, content for
    /// strings). This is what table keys use.
    pub fn keyEql(a: Value, b: Value) bool {
        if (a.kind() != b.kind()) return false;
        return switch (a) {
            .null => true,
            .bool => |x| x == b.bool,
            .int => |x| x == b.int,
            .float => |x| x == b.float,
            .string => |x| x.eql(b.string),
            .table => |x| x == b.table,
            .function => |x| x == b.function,
            .userdata => |x| x == b.userdata,
            .thread => |x| x == b.thread,
        };
    }

    pub fn keyHash(v: Value) u64 {
        return switch (v) {
            .null => 0,
            .bool => |b| if (b) 0x9e3779b97f4a7c15 else 0x7f4a7c159e3779b9,
            .int => |i| std.hash.int(@as(u64, @bitCast(i))),
            .float => |f| std.hash.int(@as(u64, @bitCast(f)) ^ 0x5851f42d4c957f2d),
            .string => |s| s.hash(),
            .table => |t| std.hash.int(@intFromPtr(t)),
            .function => |c| std.hash.int(@intFromPtr(c)),
            .userdata => |u| std.hash.int(@intFromPtr(u)),
            .thread => |t| std.hash.int(@intFromPtr(t)),
        };
    }

    /// slang ==: numeric across int/double, structural for tables, prototype
    /// identity for functions, identity otherwise.
    pub fn equals(a: Value, b: Value) bool {
        return switch (a) {
            .null => b == .null,
            .bool => |x| b == .bool and x == b.bool,
            .int => |x| switch (b) {
                .int => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            },
            .float => |x| switch (b) {
                .float => |y| x == y,
                .int => |y| x == @as(f64, @floatFromInt(y)),
                else => false,
            },
            .string => |x| b == .string and x.eql(b.string),
            .table => |x| b == .table and x.equals(b.table),
            .function => |x| blk: {
                if (b != .function) break :blk false;
                const y = b.function;
                if (x == y) break :blk true;
                break :blk x.proto != null and x.proto == y.proto;
            },
            .userdata => |x| b == .userdata and x == b.userdata,
            .thread => |x| b == .thread and x == b.thread,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
}

test "truthiness" {
    const T = @import("table.zig").Table;
    var t = T.init(std.testing.allocator, 0, 0);
    defer t.deinit(std.testing.allocator);
    const tv: Value = .{ .table = &t };
    try std.testing.expect(tv.truthy());
    try std.testing.expect(!Value.nil.truthy());
    try std.testing.expect(!(Value{ .bool = false }).truthy());
    try std.testing.expect((Value{ .int = 0 }).truthy());
}
