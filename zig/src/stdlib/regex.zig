//! slang/regex: regular expressions in RE2/Go syntax, without
//! backreferences or lookaround, so matching takes time linear in the input
//! (times the size of the pattern).
//!
//! A pattern is parsed into a tree and compiled into a small program that a
//! backtracking matcher runs, Go's backtrack.go strategy: every (instruction,
//! position) state is visited at most once per search, which bounds the work
//! and keeps leftmost-first (Perl) semantics. A greedy repetition of a
//! single character compiles to one `run` instruction, and a pattern that is
//! just one character class or one run takes a direct path, so scanning with
//! them costs about what a hand-written loop does.
//!
//! Positions are byte offsets; `.` and classes match one UTF-8 character
//! (an invalid byte counts as one character, U+FFFD). Case folding with
//! (?i) is ASCII only, and \d \w \s are ASCII as in Go.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const decodeRune = @import("stringlib.zig").decodeRune;

const Allocator = std.mem.Allocator;

pub const tname = "regex";

pub fn module(vm: *VM) *Table {
    const meta = vm.newTable(0, 3);
    meta.set(vm.gpa, vm.str("__index"), .{ .table = stdlib.makeModule(vm, &.{
        .{ .name = "matches", .f = reMatches },
        .{ .name = "match_at", .f = reMatchAt },
        .{ .name = "find", .f = reFind },
        .{ .name = "find_all", .f = reFindAll },
        .{ .name = "replace", .f = reReplace },
        .{ .name = "split", .f = reSplit },
        .{ .name = "pattern", .f = rePattern },
        .{ .name = "group_names", .f = reGroupNames },
    }) });
    meta.set(vm.gpa, vm.str("__type"), vm.str("regex"));
    vm.registry.set(vm.gpa, vm.str("regex_meta"), .{ .table = meta });
    return stdlib.makeModule(vm, &.{
        .{ .name = "compile", .f = reCompile },
        .{ .name = "escape", .f = reEscape },
    });
}

// ------------------------------------------------------------ classes

/// A set of code points: a bitmap for ASCII and sorted, disjoint ranges for
/// the rest.
const Class = struct {
    ascii: [2]u64 = .{ 0, 0 },
    ranges: []const [2]u21 = &.{},

    fn has(c: *const Class, r: u21) bool {
        if (r < 128) return (c.ascii[r >> 6] >> @intCast(r & 63)) & 1 != 0;
        var lo: usize = 0;
        var hi: usize = c.ranges.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rg = c.ranges[mid];
            if (r < rg[0]) {
                hi = mid;
            } else if (r > rg[1]) {
                lo = mid + 1;
            } else return true;
        }
        return false;
    }

    /// Whether the class can match a character that does not start with an
    /// ASCII byte.
    fn hasNonAscii(c: *const Class) bool {
        return c.ranges.len > 0;
    }
};

/// Collects ranges while a class is parsed.
const ClassBuilder = struct {
    ranges: std.ArrayList([2]u21) = .empty,

    fn add(b: *ClassBuilder, gpa: Allocator, lo: u21, hi: u21) void {
        b.ranges.append(gpa, .{ lo, hi }) catch oom();
    }

    fn addFolded(b: *ClassBuilder, gpa: Allocator, lo: u21, hi: u21, fold: bool) void {
        b.add(gpa, lo, hi);
        if (!fold) return;
        // ASCII case folding: the overlap with a-z and A-Z, shifted
        const l1 = @max(lo, 'a');
        const h1 = @min(hi, 'z');
        if (l1 <= h1) b.add(gpa, l1 - 32, h1 - 32);
        const l2 = @max(lo, 'A');
        const h2 = @min(hi, 'Z');
        if (l2 <= h2) b.add(gpa, l2 + 32, h2 + 32);
    }

    fn addPerl(b: *ClassBuilder, gpa: Allocator, kind: u8) void {
        var tmp: ClassBuilder = .{};
        defer tmp.ranges.deinit(gpa);
        const lower = std.ascii.toLower(kind);
        switch (lower) {
            'd' => tmp.add(gpa, '0', '9'),
            'w' => {
                tmp.add(gpa, '0', '9');
                tmp.add(gpa, 'A', 'Z');
                tmp.add(gpa, '_', '_');
                tmp.add(gpa, 'a', 'z');
            },
            's' => {
                tmp.add(gpa, '\t', '\n');
                tmp.add(gpa, 0x0c, '\r');
                tmp.add(gpa, ' ', ' ');
            },
            else => unreachable,
        }
        if (kind != lower) {
            const neg = tmp.complement(gpa);
            defer gpa.free(neg);
            for (neg) |r| b.add(gpa, r[0], r[1]);
        } else {
            for (tmp.ranges.items) |r| b.add(gpa, r[0], r[1]);
        }
    }

    fn lessThan(_: void, a: [2]u21, b: [2]u21) bool {
        return a[0] < b[0];
    }

    /// The ranges sorted and merged.
    fn merged(b: *ClassBuilder, gpa: Allocator) [][2]u21 {
        std.mem.sort([2]u21, b.ranges.items, {}, lessThan);
        var out: std.ArrayList([2]u21) = .empty;
        for (b.ranges.items) |r| {
            if (out.items.len > 0) {
                const last = &out.items[out.items.len - 1];
                if (@as(u32, r[0]) <= @as(u32, last[1]) + 1) {
                    last[1] = @max(last[1], r[1]);
                    continue;
                }
            }
            out.append(gpa, r) catch oom();
        }
        return out.toOwnedSlice(gpa) catch oom();
    }

    fn complement(b: *ClassBuilder, gpa: Allocator) [][2]u21 {
        const m = b.merged(gpa);
        defer gpa.free(m);
        var out: std.ArrayList([2]u21) = .empty;
        var next: u32 = 0;
        for (m) |r| {
            if (r[0] > next) out.append(gpa, .{ @intCast(next), r[0] - 1 }) catch oom();
            next = @as(u32, r[1]) + 1;
        }
        if (next <= 0x10FFFF) out.append(gpa, .{ @intCast(next), 0x10FFFF }) catch oom();
        return out.toOwnedSlice(gpa) catch oom();
    }

    fn finish(b: *ClassBuilder, gpa: Allocator, negate: bool) Class {
        const rs = if (negate) b.complement(gpa) else b.merged(gpa);
        defer gpa.free(rs);
        var c: Class = .{};
        var rest: std.ArrayList([2]u21) = .empty;
        for (rs) |r| {
            var lo = r[0];
            while (lo <= r[1] and lo < 128) : (lo += 1) c.ascii[lo >> 6] |= @as(u64, 1) << @intCast(lo & 63);
            if (r[1] >= 128) rest.append(gpa, .{ @max(r[0], 128), r[1] }) catch oom();
        }
        c.ranges = rest.toOwnedSlice(gpa) catch oom();
        b.ranges.deinit(gpa);
        return c;
    }
};

// ------------------------------------------------------------ syntax tree

const Assert = enum(u8) { begin_text, end_text, begin_line, end_line, word, not_word };

const Node = union(enum) {
    empty,
    char: u21,
    class: u32,
    any: bool, // true: also \n
    concat: []*Node,
    alt: []*Node,
    repeat: struct { sub: *Node, min: u32, max: ?u32, greedy: bool },
    group: struct { sub: *Node, index: ?u32 },
    assert: Assert,
};

const Flags = struct { fold: bool = false, multiline: bool = false, dotall: bool = false, ungreedy: bool = false };

const ParseError = error{Syntax};

const max_repeat = 1000;
const max_program = 100_000;

const Parser = struct {
    gpa: Allocator,
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    flags: Flags = .{},
    classes: std.ArrayList(Class) = .empty,
    ncap: u32 = 0,
    names: std.ArrayList([]u8) = .empty,
    err: []const u8 = "",
    err_pos: usize = 0,

    fn fail(p: *Parser, msg: []const u8, at: usize) ParseError {
        p.err = msg;
        p.err_pos = at;
        return error.Syntax;
    }

    fn node(p: *Parser, n: Node) *Node {
        const ptr = p.arena.create(Node) catch oom();
        ptr.* = n;
        return ptr;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn nextRune(p: *Parser) u21 {
        const r = decodeRune(p.src, p.pos);
        p.pos += r.len;
        return r.r;
    }

    fn addClass(p: *Parser, c: Class) u32 {
        p.classes.append(p.gpa, c) catch oom();
        return @intCast(p.classes.items.len - 1);
    }

    fn literal(p: *Parser, r: u21) *Node {
        if (p.flags.fold and r < 128 and std.ascii.isAlphabetic(@intCast(r))) {
            var b: ClassBuilder = .{};
            b.addFolded(p.gpa, r, r, true);
            return p.node(.{ .class = p.addClass(b.finish(p.gpa, false)) });
        }
        return p.node(.{ .char = r });
    }

    fn parseAlt(p: *Parser) ParseError!*Node {
        var alts: std.ArrayList(*Node) = .empty;
        alts.append(p.arena, try p.parseConcat()) catch oom();
        while (p.peek() == '|') {
            p.pos += 1;
            alts.append(p.arena, try p.parseConcat()) catch oom();
        }
        if (alts.items.len == 1) return alts.items[0];
        return p.node(.{ .alt = alts.items });
    }

    fn parseConcat(p: *Parser) ParseError!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            const atom = try p.parseRepeat();
            // a bare (?i) (which changes the flags for the rest of the
            // group) and an empty \Q\E add nothing
            if (atom.* == .empty) continue;
            items.append(p.arena, atom) catch oom();
        }
        if (items.items.len == 0) return p.node(.empty);
        if (items.items.len == 1) return items.items[0];
        return p.node(.{ .concat = items.items });
    }

    fn parseRepeat(p: *Parser) ParseError!*Node {
        var atom = try p.parseAtom();
        var repeated = false;
        while (p.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            const at = p.pos;
            switch (c) {
                '*' => p.pos += 1,
                '+' => {
                    p.pos += 1;
                    min = 1;
                },
                '?' => {
                    p.pos += 1;
                    max = 1;
                },
                '{' => {
                    const r = p.parseBraces() orelse break;
                    min = r.min;
                    max = r.max;
                },
                else => break,
            }
            if (repeated) return p.fail("invalid nested repetition operator", at);
            if (atom.* == .empty) return p.fail("missing argument to repetition operator", at);
            var greedy = true;
            if (p.peek() == '?') {
                p.pos += 1;
                greedy = false;
            }
            if (p.flags.ungreedy) greedy = !greedy;
            atom = p.node(.{ .repeat = .{ .sub = atom, .min = min, .max = max, .greedy = greedy } });
            repeated = true;
        }
        return atom;
    }

    /// {n}, {n,} or {n,m} at pos; null (and pos unchanged) when the brace is
    /// not a repetition, which makes it a literal.
    fn parseBraces(p: *Parser) ?struct { min: u32, max: ?u32 } {
        const save = p.pos;
        p.pos += 1;
        const lo = p.parseNumber() orelse {
            p.pos = save;
            return null;
        };
        var hi: ?u32 = lo;
        if (p.peek() == ',') {
            p.pos += 1;
            hi = if (p.peek() == '}') null else (p.parseNumber() orelse {
                p.pos = save;
                return null;
            });
        }
        if (p.peek() != '}') {
            p.pos = save;
            return null;
        }
        p.pos += 1;
        return .{ .min = lo, .max = hi };
    }

    fn parseNumber(p: *Parser) ?u32 {
        const start = p.pos;
        while (p.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            p.pos += 1;
        }
        if (p.pos == start) return null;
        return std.fmt.parseInt(u32, p.src[start..p.pos], 10) catch std.math.maxInt(u32);
    }

    fn parseAtom(p: *Parser) ParseError!*Node {
        const c = p.peek().?;
        switch (c) {
            '(' => return p.parseGroup(),
            '[' => return p.parseClass(),
            '.' => {
                p.pos += 1;
                return p.node(.{ .any = p.flags.dotall });
            },
            '^' => {
                p.pos += 1;
                return p.node(.{ .assert = if (p.flags.multiline) .begin_line else .begin_text });
            },
            '$' => {
                p.pos += 1;
                return p.node(.{ .assert = if (p.flags.multiline) .end_line else .end_text });
            },
            '*', '+', '?' => return p.fail("missing argument to repetition operator", p.pos),
            '\\' => return p.parseEscape(),
            else => return p.literal(p.nextRune()),
        }
    }

    fn parseGroup(p: *Parser) ParseError!*Node {
        const open = p.pos;
        p.pos += 1;
        var index: ?u32 = null;
        var name: []const u8 = "";
        const saved = p.flags;
        if (p.peek() == '?') {
            p.pos += 1;
            const rest = p.src[p.pos..];
            if (std.mem.startsWith(u8, rest, "P<") or std.mem.startsWith(u8, rest, "<")) {
                p.pos += if (rest[0] == 'P') 2 else 1;
                const start = p.pos;
                while (p.peek()) |ch| {
                    if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
                    p.pos += 1;
                }
                if (p.pos == start or p.peek() != '>') return p.fail("invalid named capture", open);
                name = p.src[start..p.pos];
                for (p.names.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) return p.fail("duplicate capture group name", open);
                }
                p.pos += 1;
                p.ncap += 1;
                index = p.ncap;
            } else {
                // flags: (?i) (?-i) (?im:...) (?:...)
                var on = true;
                var flags = p.flags;
                while (true) {
                    const ch = p.peek() orelse return p.fail("missing closing )", open);
                    p.pos += 1;
                    switch (ch) {
                        'i' => flags.fold = on,
                        'm' => flags.multiline = on,
                        's' => flags.dotall = on,
                        'U' => flags.ungreedy = on,
                        '-' => {
                            if (!on) return p.fail("invalid or unsupported Perl syntax", open);
                            on = false;
                        },
                        ':' => {
                            p.flags = flags;
                            break;
                        },
                        ')' => {
                            // (?flags): for the rest of the enclosing group
                            p.flags = flags;
                            return p.node(.empty);
                        },
                        else => return p.fail("invalid or unsupported Perl syntax", open),
                    }
                }
            }
        } else {
            p.ncap += 1;
            index = p.ncap;
        }
        if (index != null) {
            while (p.names.items.len < index.?) p.names.append(p.gpa, &.{}) catch oom();
            p.names.items[index.? - 1] = p.gpa.dupe(u8, name) catch oom();
        }
        const sub = try p.parseAlt();
        if (p.peek() != ')') return p.fail("missing closing )", open);
        p.pos += 1;
        p.flags = saved;
        return p.node(.{ .group = .{ .sub = sub, .index = index } });
    }

    /// An escape outside a class.
    fn parseEscape(p: *Parser) ParseError!*Node {
        const at = p.pos;
        p.pos += 1;
        const c = p.peek() orelse return p.fail("trailing backslash at end of expression", at);
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                p.pos += 1;
                var b: ClassBuilder = .{};
                b.addPerl(p.gpa, c);
                return p.node(.{ .class = p.addClass(b.finish(p.gpa, false)) });
            },
            'b' => {
                p.pos += 1;
                return p.node(.{ .assert = .word });
            },
            'B' => {
                p.pos += 1;
                return p.node(.{ .assert = .not_word });
            },
            'A' => {
                p.pos += 1;
                return p.node(.{ .assert = .begin_text });
            },
            'z' => {
                p.pos += 1;
                return p.node(.{ .assert = .end_text });
            },
            'Q' => {
                p.pos += 1;
                const end = std.mem.indexOfPos(u8, p.src, p.pos, "\\E") orelse p.src.len;
                var items: std.ArrayList(*Node) = .empty;
                while (p.pos < end) items.append(p.arena, p.literal(p.nextRune())) catch oom();
                p.pos = @min(end + 2, p.src.len);
                if (items.items.len == 0) return p.node(.empty);
                return p.node(.{ .concat = items.items });
            },
            else => return p.literal(try p.escapeChar(at)),
        }
    }

    /// The character of an escape that stands for one (\n, \x41, \., ...),
    /// with pos after the backslash.
    fn escapeChar(p: *Parser, at: usize) ParseError!u21 {
        const c = p.peek() orelse return p.fail("trailing backslash at end of expression", at);
        p.pos += 1;
        switch (c) {
            'n' => return '\n',
            't' => return '\t',
            'r' => return '\r',
            'f' => return 0x0c,
            'v' => return 0x0b,
            'a' => return 0x07,
            '0'...'7' => {
                // octal, up to three digits; a lone \1 to \7 would be a
                // backreference, which RE2 syntax does not have
                if (c != '0') {
                    const d = p.peek() orelse return p.fail("backreferences are not supported", at);
                    if (d < '0' or d > '7') return p.fail("backreferences are not supported", at);
                }
                var v: u21 = c - '0';
                var k: usize = 1;
                while (k < 3) : (k += 1) {
                    const d = p.peek() orelse break;
                    if (d < '0' or d > '7') break;
                    v = v * 8 + (d - '0');
                    p.pos += 1;
                }
                return v;
            },
            'x' => {
                if (p.peek() == '{') {
                    p.pos += 1;
                    const start = p.pos;
                    while (p.peek()) |d| {
                        if (!std.ascii.isHex(d)) break;
                        p.pos += 1;
                    }
                    if (p.pos == start or p.peek() != '}') return p.fail("invalid escape sequence", at);
                    const v = std.fmt.parseInt(u32, p.src[start..p.pos], 16) catch return p.fail("invalid escape sequence", at);
                    p.pos += 1;
                    if (v > 0x10FFFF) return p.fail("invalid escape sequence", at);
                    return @intCast(v);
                }
                if (p.pos + 2 > p.src.len) return p.fail("invalid escape sequence", at);
                const v = std.fmt.parseInt(u8, p.src[p.pos .. p.pos + 2], 16) catch return p.fail("invalid escape sequence", at);
                p.pos += 2;
                return v;
            },
            'p', 'P' => return p.fail("Unicode classes (\\p) are not supported", at),
            else => {
                if (c < 128 and !std.ascii.isAlphanumeric(c)) return c;
                return p.fail("invalid escape sequence", at);
            },
        }
    }

    fn parseClass(p: *Parser) ParseError!*Node {
        const open = p.pos;
        p.pos += 1;
        var negate = false;
        if (p.peek() == '^') {
            p.pos += 1;
            negate = true;
        }
        var b: ClassBuilder = .{};
        var first = true;
        while (true) {
            const c = p.peek() orelse {
                b.ranges.deinit(p.gpa);
                return p.fail("missing closing ]", open);
            };
            if (c == ']' and !first) {
                p.pos += 1;
                break;
            }
            first = false;
            // [:alpha:]
            if (c == '[' and p.pos + 1 < p.src.len and p.src[p.pos + 1] == ':') {
                if (std.mem.indexOfPos(u8, p.src, p.pos + 2, ":]")) |end| {
                    var name = p.src[p.pos + 2 .. end];
                    var neg = false;
                    if (name.len > 0 and name[0] == '^') {
                        neg = true;
                        name = name[1..];
                    }
                    var tmp: ClassBuilder = .{};
                    if (!posixClass(p.gpa, &tmp, name)) {
                        tmp.ranges.deinit(p.gpa);
                        b.ranges.deinit(p.gpa);
                        return p.fail("invalid character class range", p.pos);
                    }
                    const rs = if (neg) tmp.complement(p.gpa) else tmp.merged(p.gpa);
                    defer p.gpa.free(rs);
                    tmp.ranges.deinit(p.gpa);
                    for (rs) |r| b.addFolded(p.gpa, r[0], r[1], p.flags.fold);
                    p.pos = end + 2;
                    continue;
                }
            }
            var lo: u21 = undefined;
            if (c == '\\') {
                const at = p.pos;
                p.pos += 1;
                const e = p.peek() orelse {
                    b.ranges.deinit(p.gpa);
                    return p.fail("missing closing ]", open);
                };
                if (e == 'd' or e == 'D' or e == 'w' or e == 'W' or e == 's' or e == 'S') {
                    p.pos += 1;
                    b.addPerl(p.gpa, e);
                    continue;
                }
                lo = p.escapeChar(at) catch |err| {
                    b.ranges.deinit(p.gpa);
                    return err;
                };
            } else {
                lo = p.nextRune();
            }
            var hi = lo;
            if (p.peek() == '-' and p.pos + 1 < p.src.len and p.src[p.pos + 1] != ']') {
                const at = p.pos;
                p.pos += 1;
                if (p.peek() == '\\') {
                    const eat = p.pos;
                    p.pos += 1;
                    hi = p.escapeChar(eat) catch |err| {
                        b.ranges.deinit(p.gpa);
                        return err;
                    };
                } else {
                    hi = p.nextRune();
                }
                if (hi < lo) {
                    b.ranges.deinit(p.gpa);
                    return p.fail("invalid character class range", at);
                }
            }
            b.addFolded(p.gpa, lo, hi, p.flags.fold);
        }
        return p.node(.{ .class = p.addClass(b.finish(p.gpa, negate)) });
    }
};

fn posixClass(gpa: Allocator, b: *ClassBuilder, name: []const u8) bool {
    const eql = std.mem.eql;
    if (eql(u8, name, "alnum")) {
        b.add(gpa, '0', '9');
        b.add(gpa, 'A', 'Z');
        b.add(gpa, 'a', 'z');
    } else if (eql(u8, name, "alpha")) {
        b.add(gpa, 'A', 'Z');
        b.add(gpa, 'a', 'z');
    } else if (eql(u8, name, "ascii")) {
        b.add(gpa, 0, 0x7f);
    } else if (eql(u8, name, "blank")) {
        b.add(gpa, '\t', '\t');
        b.add(gpa, ' ', ' ');
    } else if (eql(u8, name, "cntrl")) {
        b.add(gpa, 0, 0x1f);
        b.add(gpa, 0x7f, 0x7f);
    } else if (eql(u8, name, "digit")) {
        b.add(gpa, '0', '9');
    } else if (eql(u8, name, "graph")) {
        b.add(gpa, '!', '~');
    } else if (eql(u8, name, "lower")) {
        b.add(gpa, 'a', 'z');
    } else if (eql(u8, name, "print")) {
        b.add(gpa, ' ', '~');
    } else if (eql(u8, name, "punct")) {
        b.add(gpa, '!', '/');
        b.add(gpa, ':', '@');
        b.add(gpa, '[', '`');
        b.add(gpa, '{', '~');
    } else if (eql(u8, name, "space")) {
        b.add(gpa, '\t', '\r');
        b.add(gpa, ' ', ' ');
    } else if (eql(u8, name, "upper")) {
        b.add(gpa, 'A', 'Z');
    } else if (eql(u8, name, "word")) {
        b.add(gpa, '0', '9');
        b.add(gpa, 'A', 'Z');
        b.add(gpa, '_', '_');
        b.add(gpa, 'a', 'z');
    } else if (eql(u8, name, "xdigit")) {
        b.add(gpa, '0', '9');
        b.add(gpa, 'A', 'F');
        b.add(gpa, 'a', 'f');
    } else return false;
    return true;
}

// ------------------------------------------------------------ program

const Op = enum(u8) { char, class, any, any_nl, split, jmp, save, assert, run, match };

const Inst = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
};

const inf_count = std.math.maxInt(u32);

const Compiler = struct {
    gpa: Allocator,
    prog: std.ArrayList(Inst) = .empty,
    too_big: bool = false,

    fn emit(c: *Compiler, i: Inst) u32 {
        if (c.prog.items.len >= max_program) c.too_big = true;
        c.prog.append(c.gpa, i) catch oom();
        return @intCast(c.prog.items.len - 1);
    }

    /// The instruction for a node that matches exactly one character, or
    /// null.
    fn single(n: *const Node) ?Inst {
        return switch (n.*) {
            .char => |r| .{ .op = .char, .a = r },
            .class => |k| .{ .op = .class, .a = k },
            .any => |nl| .{ .op = if (nl) .any_nl else .any },
            .group => |g| if (g.index == null) single(g.sub) else null,
            else => null,
        };
    }

    fn gen(c: *Compiler, n: *const Node) void {
        if (c.too_big) return;
        switch (n.*) {
            .empty => {},
            .char, .class, .any => _ = c.emit(single(n).?),
            .assert => |k| _ = c.emit(.{ .op = .assert, .a = @intFromEnum(k) }),
            .concat => |items| for (items) |it| c.gen(it),
            .alt => |items| {
                // split L1, next; L1: a; jmp end; next: split L2, ...
                var jumps: std.ArrayList(u32) = .empty;
                defer jumps.deinit(c.gpa);
                for (items, 0..) |it, k| {
                    if (k + 1 < items.len) {
                        const sp = c.emit(.{ .op = .split });
                        c.prog.items[sp].a = sp + 1;
                        c.gen(it);
                        jumps.append(c.gpa, c.emit(.{ .op = .jmp })) catch oom();
                        c.prog.items[sp].b = @intCast(c.prog.items.len);
                    } else {
                        c.gen(it);
                    }
                }
                const end: u32 = @intCast(c.prog.items.len);
                for (jumps.items) |j| c.prog.items[j].a = end;
            },
            .group => |g| {
                if (g.index) |k| {
                    _ = c.emit(.{ .op = .save, .a = 2 * (k - 1) });
                    c.gen(g.sub);
                    _ = c.emit(.{ .op = .save, .a = 2 * (k - 1) + 1 });
                } else c.gen(g.sub);
            },
            .repeat => |r| c.genRepeat(r.sub, r.min, r.max, r.greedy),
        }
    }

    fn genRepeat(c: *Compiler, sub: *const Node, min: u32, max: ?u32, greedy: bool) void {
        if (greedy) {
            if (single(sub)) |s| {
                // one instruction: consume greedily, give back on failure
                const k: u32 = switch (s.op) {
                    .char => 0,
                    .class => 1,
                    .any => 2,
                    else => 3,
                };
                _ = c.emit(.{ .op = .run, .a = (s.a << 2) | k, .b = min, .c = max orelse inf_count });
                return;
            }
        }
        var k: u32 = 0;
        while (k < min) : (k += 1) {
            c.gen(sub);
            if (c.too_big) return;
        }
        if (max) |m| {
            // up to m - min optional copies, nested: (x(x)?)?
            var holes: std.ArrayList(u32) = .empty;
            defer holes.deinit(c.gpa);
            var left = m - min;
            while (left > 0) : (left -= 1) {
                const sp = c.emit(.{ .op = .split });
                holes.append(c.gpa, sp) catch oom();
                c.gen(sub);
                if (c.too_big) return;
            }
            const end: u32 = @intCast(c.prog.items.len);
            for (holes.items) |sp| {
                if (greedy) {
                    c.prog.items[sp].a = sp + 1;
                    c.prog.items[sp].b = end;
                } else {
                    c.prog.items[sp].a = end;
                    c.prog.items[sp].b = sp + 1;
                }
            }
        } else {
            // L: split body, end; body; jmp L
            const sp = c.emit(.{ .op = .split });
            c.gen(sub);
            const j = c.emit(.{ .op = .jmp, .a = sp });
            _ = j;
            const end: u32 = @intCast(c.prog.items.len);
            if (greedy) {
                c.prog.items[sp].a = sp + 1;
                c.prog.items[sp].b = end;
            } else {
                c.prog.items[sp].a = end;
                c.prog.items[sp].b = sp + 1;
            }
        }
    }
};

// ------------------------------------------------------------ the regex

const Shape = enum { general, one, run };

const Job = struct {
    kind: enum(u8) { step, restore, retry },
    pc: u32,
    count: u32 = 0,
    pos: usize,
    old: i64 = 0,
};

const Regex = struct {
    gpa: Allocator,
    pattern: []u8,
    prog: []Inst,
    classes: []Class,
    ncap: u32,
    names: [][]u8,
    /// the bytes a non-empty match can start with
    first: [4]u64,
    /// whether a match can be empty (asserts assumed to hold)
    nullable: bool,
    /// whether the empty match always succeeds (no assert on the way)
    empty_always: bool,
    anchored: bool,
    shape: Shape,
    // scratch, reused between searches
    jobs: std.ArrayList(Job) = .empty,
    visited: std.ArrayList(u64) = .empty,
    vis_used: usize = 0,
    base: usize = 0,
    caps: []i64,
    /// the last match: start, end, then the groups' start/end pairs
    result: []i64,

    fn deinit(re: *Regex) void {
        const gpa = re.gpa;
        gpa.free(re.pattern);
        gpa.free(re.prog);
        for (re.classes) |c| gpa.free(c.ranges);
        gpa.free(re.classes);
        for (re.names) |n| gpa.free(n);
        gpa.free(re.names);
        re.jobs.deinit(gpa);
        re.visited.deinit(gpa);
        gpa.free(re.caps);
        gpa.free(re.result);
    }

    // ---------------------------------------------------- one character

    inline fn matchOne(re: *const Regex, op: Op, a: u32, s: []const u8, pos: usize) usize {
        if (pos >= s.len) return 0;
        const b = s[pos];
        if (b < 0x80) {
            const hit = switch (op) {
                .char => b == a,
                .class => (re.classes[a].ascii[b >> 6] >> @intCast(b & 63)) & 1 != 0,
                .any => b != '\n',
                .any_nl => true,
                else => unreachable,
            };
            return if (hit) 1 else 0;
        }
        const r = decodeRune(s, pos);
        const hit = switch (op) {
            .char => r.r == a,
            .class => re.classes[a].has(r.r),
            .any, .any_nl => true,
            else => unreachable,
        };
        return if (hit) r.len else 0;
    }

    fn runOp(a: u32) struct { op: Op, arg: u32 } {
        return .{
            .op = switch (a & 3) {
                0 => .char,
                1 => .class,
                2 => .any,
                else => .any_nl,
            },
            .arg = a >> 2,
        };
    }

    // ---------------------------------------------------- the matcher

    fn shouldVisit(re: *Regex, pc: u32, pos: usize) bool {
        const bit = (pos - re.base) * re.prog.len + pc;
        const w = bit >> 6;
        if (w >= re.visited.items.len) {
            const old = re.visited.items.len;
            const want = @max(w + 1, old * 2, 64);
            re.visited.resize(re.gpa, want) catch oom();
            @memset(re.visited.items[old..], 0);
        }
        if (w >= re.vis_used) re.vis_used = w + 1;
        const m = @as(u64, 1) << @intCast(bit & 63);
        if (re.visited.items[w] & m != 0) return false;
        re.visited.items[w] |= m;
        return true;
    }

    fn reset(re: *Regex, base: usize) void {
        @memset(re.visited.items[0..re.vis_used], 0);
        re.vis_used = 0;
        re.base = base;
        re.jobs.clearRetainingCapacity();
    }

    fn assertHolds(k: Assert, s: []const u8, pos: usize) bool {
        return switch (k) {
            .begin_text => pos == 0,
            .end_text => pos == s.len,
            .begin_line => pos == 0 or s[pos - 1] == '\n',
            .end_line => pos == s.len or s[pos] == '\n',
            .word, .not_word => blk: {
                const before = pos > 0 and isWord(s[pos - 1]);
                const after = pos < s.len and isWord(s[pos]);
                break :blk (before != after) == (k == .word);
            },
        };
    }

    fn isWord(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_';
    }

    /// The start of the character before pos, consistent with decodeRune
    /// for valid UTF-8.
    fn prevStart(s: []const u8, pos: usize) usize {
        var k: usize = 1;
        while (k <= 4 and k <= pos) : (k += 1) {
            const p = pos - k;
            if (s[p] & 0xC0 != 0x80) {
                return if (decodeRune(s, p).len == k) p else pos - 1;
            }
        }
        return pos - 1;
    }

    /// Tries a match that starts at start; on success fills result.
    fn tryAt(re: *Regex, s: []const u8, start: usize) bool {
        @memset(re.caps, -1);
        re.jobs.append(re.gpa, .{ .kind = .step, .pc = 0, .pos = start }) catch oom();
        while (re.jobs.pop()) |job| {
            var pc = job.pc;
            var pos = job.pos;
            switch (job.kind) {
                .restore => {
                    re.caps[pc] = job.old;
                    continue;
                },
                .retry => {
                    // the run at pc gives back one more character
                    const inst = re.prog[pc];
                    const np = prevStart(s, pos);
                    const count = job.count - 1;
                    if (count > inst.b) re.jobs.append(re.gpa, .{ .kind = .retry, .pc = pc, .pos = np, .count = count }) catch oom();
                    pc += 1;
                    pos = np;
                },
                .step => {},
            }
            while (true) {
                if (!re.shouldVisit(pc, pos)) break;
                const inst = re.prog[pc];
                switch (inst.op) {
                    .char, .class, .any, .any_nl => {
                        const n = re.matchOne(inst.op, inst.a, s, pos);
                        if (n == 0) break;
                        pos += n;
                        pc += 1;
                    },
                    .split => {
                        re.jobs.append(re.gpa, .{ .kind = .step, .pc = inst.b, .pos = pos }) catch oom();
                        pc = inst.a;
                    },
                    .jmp => pc = inst.a,
                    .save => {
                        re.jobs.append(re.gpa, .{ .kind = .restore, .pc = inst.a, .pos = 0, .old = re.caps[inst.a] }) catch oom();
                        re.caps[inst.a] = @intCast(pos);
                        pc += 1;
                    },
                    .assert => {
                        if (!assertHolds(@enumFromInt(inst.a), s, pos)) break;
                        pc += 1;
                    },
                    .run => {
                        const o = runOp(inst.a);
                        var count: u32 = 0;
                        var end = pos;
                        while (count < inst.c) {
                            const n = re.matchOne(o.op, o.arg, s, end);
                            if (n == 0) break;
                            end += n;
                            count += 1;
                        }
                        if (count < inst.b) break;
                        if (count > inst.b) re.jobs.append(re.gpa, .{ .kind = .retry, .pc = pc, .pos = end, .count = count }) catch oom();
                        pos = end;
                        pc += 1;
                    },
                    .match => {
                        re.result[0] = @intCast(start);
                        re.result[1] = @intCast(pos);
                        @memcpy(re.result[2..], re.caps);
                        return true;
                    },
                }
            }
        }
        return false;
    }

    /// The end of a match anchored at pos, or null; fills result.
    fn matchAt(re: *Regex, s: []const u8, pos: usize) ?usize {
        switch (re.shape) {
            .one => {
                const i = re.prog[0];
                const n = re.matchOne(i.op, i.a, s, pos);
                if (n == 0) return null;
                re.result[0] = @intCast(pos);
                re.result[1] = @intCast(pos + n);
                return pos + n;
            },
            .run => {
                const i = re.prog[0];
                const o = runOp(i.a);
                var count: u32 = 0;
                var end = pos;
                while (count < i.c) {
                    const n = re.matchOne(o.op, o.arg, s, end);
                    if (n == 0) break;
                    end += n;
                    count += 1;
                }
                if (count < i.b) return null;
                re.result[0] = @intCast(pos);
                re.result[1] = @intCast(end);
                return end;
            },
            .general => {
                // a byte no match starts with decides at once
                if (pos >= s.len or !re.firstHas(s[pos])) {
                    if (!re.nullable) return null;
                    if (re.empty_always and re.ncap == 0) {
                        re.result[0] = @intCast(pos);
                        re.result[1] = @intCast(pos);
                        return pos;
                    }
                }
                re.reset(pos);
                if (!re.tryAt(s, pos)) return null;
                return @intCast(re.result[1]);
            },
        }
    }

    /// The leftmost match at or after from; fills result.
    fn search(re: *Regex, s: []const u8, from: usize) bool {
        if (from > s.len) return false;
        if (re.anchored and from > 0) return false;
        if (re.shape != .general) {
            var pos = from;
            while (pos <= s.len) {
                if (re.canStart(s, pos)) {
                    if (re.matchAt(s, pos) != null) return true;
                }
                if (pos == s.len) break;
                pos += decodeRune(s, pos).len;
            }
            return false;
        }
        re.reset(from);
        var pos = from;
        while (pos <= s.len) {
            if (re.canStart(s, pos)) {
                if (re.tryAt(s, pos)) return true;
            }
            if (pos == s.len or re.anchored) break;
            pos += decodeRune(s, pos).len;
        }
        return false;
    }

    inline fn firstHas(re: *const Regex, b: u8) bool {
        return (re.first[b >> 6] >> @intCast(b & 63)) & 1 != 0;
    }

    inline fn canStart(re: *const Regex, s: []const u8, pos: usize) bool {
        if (re.nullable) return true;
        if (pos >= s.len) return false;
        return re.firstHas(s[pos]);
    }
};

const Analysis = struct { first: [4]u64, nullable: bool, empty_always: bool };

/// The bytes a non-empty match can start with, and whether the program can
/// match the empty string: at all (asserts assumed to hold), and with no
/// assert on the way.
fn analyze(gpa: Allocator, prog: []const Inst, classes: []const Class) Analysis {
    var r: Analysis = .{ .first = .{ 0, 0, 0, 0 }, .nullable = false, .empty_always = false };
    // states (pc, passed an assert): seen[2 * pc + asserted]
    var seen = gpa.alloc(bool, 2 * prog.len) catch oom();
    defer gpa.free(seen);
    @memset(seen, false);
    const State = struct { pc: u32, asserted: bool };
    var stack: std.ArrayList(State) = .empty;
    defer stack.deinit(gpa);
    stack.append(gpa, .{ .pc = 0, .asserted = false }) catch oom();
    const add = struct {
        fn byte(set: *[4]u64, b: u8) void {
            set[b >> 6] |= @as(u64, 1) << @intCast(b & 63);
        }
        fn range(set: *[4]u64, lo: u8, hi: u8) void {
            var b: u16 = lo;
            while (b <= hi) : (b += 1) byte(set, @intCast(b));
        }
        fn one(set: *[4]u64, op: Op, a: u32, cls: []const Class) void {
            switch (op) {
                .char => {
                    var buf: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(@intCast(a), &buf)) |_| byte(set, buf[0]) else |_| range(set, 0x80, 0xFF);
                },
                .class => {
                    const c = &cls[a];
                    set[0] |= c.ascii[0];
                    set[1] |= c.ascii[1];
                    if (c.hasNonAscii()) range(set, 0x80, 0xFF);
                },
                .any => {
                    range(set, 0, 9);
                    range(set, 11, 0xFF);
                },
                else => range(set, 0, 0xFF),
            }
        }
    };
    while (stack.pop()) |st| {
        const k = 2 * @as(usize, st.pc) + @intFromBool(st.asserted);
        if (seen[k]) continue;
        seen[k] = true;
        const i = prog[st.pc];
        switch (i.op) {
            .char, .class, .any, .any_nl => add.one(&r.first, i.op, i.a, classes),
            .run => {
                const o = Regex.runOp(i.a);
                add.one(&r.first, o.op, o.arg, classes);
                if (i.b == 0) stack.append(gpa, .{ .pc = st.pc + 1, .asserted = st.asserted }) catch oom();
            },
            .split => {
                stack.append(gpa, .{ .pc = i.a, .asserted = st.asserted }) catch oom();
                stack.append(gpa, .{ .pc = i.b, .asserted = st.asserted }) catch oom();
            },
            .jmp => stack.append(gpa, .{ .pc = i.a, .asserted = st.asserted }) catch oom(),
            .save => stack.append(gpa, .{ .pc = st.pc + 1, .asserted = st.asserted }) catch oom(),
            .assert => stack.append(gpa, .{ .pc = st.pc + 1, .asserted = true }) catch oom(),
            .match => {
                r.nullable = true;
                if (!st.asserted) r.empty_always = true;
            },
        }
    }
    return r;
}

const CompileError = struct { msg: []const u8, pos: usize };

fn compile(gpa: Allocator, pattern: []const u8, err: *CompileError) ?Regex {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var p: Parser = .{ .gpa = gpa, .arena = arena_state.allocator(), .src = pattern };
    const tree = p.parseAlt() catch {
        err.* = .{ .msg = p.err, .pos = p.err_pos };
        for (p.classes.items) |c| gpa.free(c.ranges);
        p.classes.deinit(gpa);
        for (p.names.items) |n| gpa.free(n);
        p.names.deinit(gpa);
        return null;
    };
    if (p.pos < pattern.len) {
        // only an unmatched ) stops the parser early
        err.* = .{ .msg = "unexpected )", .pos = p.pos };
        for (p.classes.items) |c| gpa.free(c.ranges);
        p.classes.deinit(gpa);
        for (p.names.items) |n| gpa.free(n);
        p.names.deinit(gpa);
        return null;
    }
    var c: Compiler = .{ .gpa = gpa };
    if (repeatTooLarge(tree)) {
        err.* = .{ .msg = "invalid repeat count", .pos = 0 };
    } else {
        c.gen(tree);
        _ = c.emit(.{ .op = .match });
    }
    if (c.too_big or err.msg.len > 0) {
        if (err.msg.len == 0) err.* = .{ .msg = "expression too large", .pos = 0 };
        c.prog.deinit(gpa);
        for (p.classes.items) |cl| gpa.free(cl.ranges);
        p.classes.deinit(gpa);
        for (p.names.items) |n| gpa.free(n);
        p.names.deinit(gpa);
        return null;
    }
    const prog = c.prog.toOwnedSlice(gpa) catch oom();
    const classes = p.classes.toOwnedSlice(gpa) catch oom();
    while (p.names.items.len < p.ncap) p.names.append(gpa, &.{}) catch oom();
    const ncap = p.ncap;
    var shape: Shape = .general;
    if (prog.len == 2 and ncap == 0) {
        shape = switch (prog[0].op) {
            .char, .class, .any, .any_nl => .one,
            .run => .run,
            else => .general,
        };
    }
    const an = analyze(gpa, prog, classes);
    return .{
        .gpa = gpa,
        .pattern = gpa.dupe(u8, pattern) catch oom(),
        .prog = prog,
        .classes = classes,
        .ncap = ncap,
        .names = p.names.toOwnedSlice(gpa) catch oom(),
        .first = an.first,
        .nullable = an.nullable,
        .empty_always = an.empty_always,
        .anchored = prog.len > 0 and prog[0].op == .assert and prog[0].a == @intFromEnum(Assert.begin_text),
        .shape = shape,
        .caps = gpa.alloc(i64, 2 * ncap) catch oom(),
        .result = gpa.alloc(i64, 2 * ncap + 2) catch oom(),
    };
}

fn repeatTooLarge(n: *const Node) bool {
    return switch (n.*) {
        .repeat => |r| r.min > max_repeat or (r.max != null and (r.max.? > max_repeat or r.max.? < r.min)) or repeatTooLarge(r.sub),
        .group => |g| repeatTooLarge(g.sub),
        .concat, .alt => |items| for (items) |it| {
            if (repeatTooLarge(it)) break true;
        } else false,
        else => false,
    };
}

// ------------------------------------------------------------ natives

fn finalize(data: ?*anyopaque) callconv(.c) void {
    const re: *Regex = @ptrCast(@alignCast(data.?));
    re.deinit();
}

fn toString(u: *Userdata, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("regex({s})", .{u.as(Regex).pattern});
}

fn self(th: *Thread, args: []Value) Error!*Regex {
    return api.argUserdata(th, args, 0, "regex", Regex, tname);
}

/// compile(pattern) -> Regex; raises on a syntax error.
fn reCompile(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const pattern = try api.argString(th, args, 0, "pattern");
    var err: CompileError = .{ .msg = "", .pos = 0 };
    const re = compile(vm.gpa, pattern, &err) orelse {
        return vm.raise("regex: {s} at offset {d} in `{s}`", .{ err.msg, err.pos, pattern });
    };
    const meta = vm.registry.getName("regex_meta").asTable();
    const u = vm.newUserdataOf(Regex, re, tname, meta);
    u.finalizer = finalize;
    u.to_string = toString;
    return .{ .userdata = u };
}

/// escape(s): s with every regex metacharacter escaped.
fn reEscape(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(th.vm.gpa);
    for (s) |b| {
        if (std.mem.indexOfScalar(u8, "\\.+*?()|[]{}^$", b) != null) out.append(th.vm.gpa, '\\') catch oom();
        out.append(th.vm.gpa, b) catch oom();
    }
    return th.vm.str(out.items);
}

fn startArg(args: []Value, i: usize, len: usize) ?usize {
    const v = api.argIntOr(args, i, 0);
    if (v < 0) return 0;
    if (v > len) return null;
    return @intCast(v);
}

fn reMatches(th: *Thread, args: []Value) Error!Value {
    const re = try self(th, args);
    const s = try api.argString(th, args, 1, "str");
    return .{ .bool = re.search(s, 0) };
}

/// match_at(s, [pos]): the end of a match that starts exactly at pos, or -1.
fn reMatchAt(th: *Thread, args: []Value) Error!Value {
    const re = try self(th, args);
    const s = try api.argString(th, args, 1, "str");
    const pos = startArg(args, 2, s.len) orelse return .{ .int = -1 };
    const end = re.matchAt(s, pos) orelse return .{ .int = -1 };
    return .{ .int = @intCast(end) };
}

/// The match table of result: {text, start, end, groups, spans, named}.
fn matchTable(vm: *VM, re: *const Regex, s: []const u8, result: []const i64) Value {
    const gpa = vm.gpa;
    const t = vm.newTable(0, 6);
    const start: usize = @intCast(result[0]);
    const end: usize = @intCast(result[1]);
    t.set(gpa, vm.str("text"), vm.str(s[start..end]));
    t.set(gpa, vm.str("start"), .{ .int = @intCast(start) });
    t.set(gpa, vm.str("end"), .{ .int = @intCast(end) });
    const groups = vm.newTable(re.ncap + 1, 0);
    const spans = vm.newTable(re.ncap + 1, 0);
    const named = vm.newTable(0, 0);
    var k: usize = 0;
    while (k <= re.ncap) : (k += 1) {
        const a = result[2 * k];
        const b = result[2 * k + 1];
        const span = vm.newTable(2, 0);
        span.append(gpa, .{ .int = a });
        span.append(gpa, .{ .int = b });
        spans.append(gpa, .{ .table = span });
        if (a >= 0 and b >= 0) {
            const text = vm.str(s[@intCast(a)..@intCast(b)]);
            groups.append(gpa, text);
            if (k > 0 and re.names[k - 1].len > 0) named.set(gpa, vm.str(re.names[k - 1]), text);
        } else {
            groups.append(gpa, vm.str(""));
        }
    }
    t.set(gpa, vm.str("groups"), .{ .table = groups });
    t.set(gpa, vm.str("spans"), .{ .table = spans });
    t.set(gpa, vm.str("named"), .{ .table = named });
    return .{ .table = t };
}

/// The result of the last search in the order matchTable reads it: whole
/// match first, then the groups.
fn snapshot(re: *const Regex, buf: []i64) []i64 {
    const out = buf[0..re.result.len];
    @memcpy(out, re.result);
    if (re.shape != .general) @memset(out[2..], -1);
    return out;
}

/// find(s, [from]): the leftmost match at or after from, or null.
fn reFind(th: *Thread, args: []Value) Error!Value {
    const re = try self(th, args);
    const s = try api.argString(th, args, 1, "str");
    const from = startArg(args, 2, s.len) orelse return .null;
    if (!re.search(s, from)) return .null;
    const buf = th.vm.gpa.alloc(i64, re.result.len) catch oom();
    defer th.vm.gpa.free(buf);
    return matchTable(th.vm, re, s, snapshot(re, buf));
}

/// Walks the matches the way Go's FindAll does: an empty match right after
/// a match is skipped, and after an empty match the search moves on by one
/// character. f gets each match's result; it returns false to stop.
fn eachMatch(re: *Regex, s: []const u8, limit: i64, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const i64) Error!bool) Error!void {
    var pos: usize = 0;
    var prev_end: i64 = -1;
    var count: i64 = 0;
    const buf = re.gpa.alloc(i64, re.result.len) catch oom();
    defer re.gpa.free(buf);
    while (pos <= s.len and (limit < 0 or count < limit)) {
        if (!re.search(s, pos)) break;
        const r = snapshot(re, buf);
        var accept = true;
        const end: usize = @intCast(r[1]);
        if (end == r[0]) {
            if (r[0] == prev_end) accept = false;
            pos = if (end < s.len) end + decodeRune(s, end).len else s.len + 1;
        } else {
            pos = end;
        }
        prev_end = r[1];
        if (accept) {
            count += 1;
            if (!try f(ctx, r)) break;
        }
    }
}

/// find_all(s, [n]): every match (at most n), as find gives them.
fn reFindAll(th: *Thread, args: []Value) Error!Value {
    const re = try self(th, args);
    const s = try api.argString(th, args, 1, "str");
    const n = api.argIntOr(args, 2, -1);
    const out = th.vm.newTable(0, 0);
    const Ctx = struct { vm: *VM, re: *Regex, s: []const u8, out: *Table };
    try eachMatch(re, s, n, Ctx{ .vm = th.vm, .re = re, .s = s, .out = out }, struct {
        fn f(c: Ctx, r: []const i64) Error!bool {
            c.out.append(c.vm.gpa, matchTable(c.vm, c.re, c.s, r));
            return true;
        }
    }.f);
    return .{ .table = out };
}

/// split(s, [n]): the parts of s between the matches (Go's Regexp.Split).
fn reSplit(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const re = try self(th, args);
    const s = try api.argString(th, args, 1, "str");
    const n = api.argIntOr(args, 2, -1);
    const out = vm.newTable(0, 0);
    if (n == 0) return .{ .table = out };
    if (s.len == 0) {
        // Go: an empty input is one empty part, unless the pattern is empty
        if (re.pattern.len > 0) out.append(vm.gpa, vm.str(""));
        return .{ .table = out };
    }
    const Ctx = struct { vm: *VM, s: []const u8, out: *Table, n: i64, beg: *usize, end: *usize };
    var beg: usize = 0;
    var end: usize = 0;
    try eachMatch(re, s, n, Ctx{ .vm = vm, .s = s, .out = out, .n = n, .beg = &beg, .end = &end }, struct {
        fn f(c: Ctx, r: []const i64) Error!bool {
            if (c.n > 0 and c.out.arrayLen() == c.n - 1) return false;
            c.end.* = @intCast(r[0]);
            if (r[1] != 0) c.out.append(c.vm.gpa, c.vm.str(c.s[c.beg.*..c.end.*]));
            c.beg.* = @intCast(r[1]);
            return true;
        }
    }.f);
    if (end != s.len) out.append(vm.gpa, vm.str(s[beg..]));
    return .{ .table = out };
}

/// Appends repl with $1, ${1}, $name, ${name} and $$ expanded.
fn expand(gpa: Allocator, out: *std.ArrayList(u8), repl: []const u8, re: *const Regex, s: []const u8, r: []const i64) void {
    var i: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c != '$' or i + 1 >= repl.len) {
            out.append(gpa, c) catch oom();
            i += 1;
            continue;
        }
        i += 1;
        if (repl[i] == '$') {
            out.append(gpa, '$') catch oom();
            i += 1;
            continue;
        }
        var name: []const u8 = undefined;
        if (repl[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, repl, i, '}') orelse {
                out.append(gpa, '$') catch oom();
                continue;
            };
            name = repl[i + 1 .. close];
            i = close + 1;
        } else {
            const start = i;
            while (i < repl.len and (std.ascii.isAlphanumeric(repl[i]) or repl[i] == '_')) i += 1;
            if (i == start) {
                out.append(gpa, '$') catch oom();
                continue;
            }
            name = repl[start..i];
        }
        var k: ?usize = null;
        if (std.fmt.parseInt(usize, name, 10)) |num| {
            if (num <= re.ncap) k = num;
        } else |_| {
            for (re.names, 0..) |nm, j| {
                if (nm.len > 0 and std.mem.eql(u8, nm, name)) k = j + 1;
            }
        }
        if (k) |g| {
            const a = r[2 * g];
            const b = r[2 * g + 1];
            if (a >= 0 and b >= 0) out.appendSlice(gpa, s[@intCast(a)..@intCast(b)]) catch oom();
        }
    }
}

/// replace(s, repl, [n]): s with the matches (the first n) replaced by repl,
/// a string with $1/${name} references or a function given the match.
fn reReplace(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const re = try self(th, args);
    const s = try api.argString(th, args, 1, "str");
    const repl = api.arg(args, 2);
    if (repl != .string and repl != .function) return api.argError(th, "replacement", 2, "string or function", repl);
    const n = api.argIntOr(args, 3, -1);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var last: usize = 0;
    const Ctx = struct { th: *Thread, re: *Regex, s: []const u8, repl: Value, out: *std.ArrayList(u8), last: *usize };
    try eachMatch(re, s, n, Ctx{ .th = th, .re = re, .s = s, .repl = repl, .out = &out, .last = &last }, struct {
        fn f(c: Ctx, r: []const i64) Error!bool {
            const gpa = c.th.vm.gpa;
            const start: usize = @intCast(r[0]);
            c.out.appendSlice(gpa, c.s[c.last.*..start]) catch oom();
            switch (c.repl) {
                .string => |rs| expand(gpa, c.out, rs.bytes(), c.re, c.s, r),
                else => {
                    // the match is copied first: the function may use this
                    // regex too, which reuses its scratch memory
                    const m = matchTable(c.th.vm, c.re, c.s, r);
                    const v = try c.th.call(c.repl, &.{m});
                    const text = v.asBytes() orelse return c.th.vm.raise("replace: the function returned {s}, not a string", .{v.typeName()});
                    c.out.appendSlice(gpa, text) catch oom();
                },
            }
            c.last.* = @intCast(r[1]);
            return true;
        }
    }.f);
    out.appendSlice(vm.gpa, s[last..]) catch oom();
    return vm.str(out.items);
}

fn rePattern(th: *Thread, args: []Value) Error!Value {
    const re = try self(th, args);
    return th.vm.str(re.pattern);
}

/// group_names(): the names of the groups by number; index 0 (the whole
/// match) and unnamed groups are "".
fn reGroupNames(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const re = try self(th, args);
    const t = vm.newTable(re.ncap + 1, 0);
    t.append(vm.gpa, vm.str(""));
    for (re.names) |nm| t.append(vm.gpa, vm.str(nm));
    return .{ .table = t };
}
