//! slang/time: wall-clock time as seconds since the Unix epoch, in UTC.
//!
//!   now() -> seconds (float, millisecond precision)
//!   utc(t) -> {year, month, day, hour, minute, second, ms, weekday, yday}
//!   from_utc({year, month, day, hour, minute, second, ms}) -> seconds
//!   http_date(t) -> "Sun, 06 Nov 1994 08:49:37 GMT"
//!   parse_http_date(s) -> seconds or null
//!   iso(t) -> "1994-11-06T08:49:37Z" (".123" before the Z when t has ms)
//!   parse_iso(s) -> seconds or null
//!
//! Months and days count from 1, weekday from 0 (Sunday), yday from 1.
//! from_utc normalizes, so {year: 2026, month: 13, day: 1} is January 2027
//! and adding 30 to day moves 30 days on. parse_http_date accepts the three
//! forms RFC 9110 requires (RFC 1123, RFC 850, asctime); parse_iso accepts
//! RFC 3339 and the common ISO 8601 forms: a date alone, "T" or a space
//! before the time, seconds and fraction optional, "Z", "+hh:mm", "+hhmm",
//! "+hh" or nothing (UTC) for the zone; so SQLite's datetime() parses.
//! Parsers return an int, or a float when the input had a fraction. There
//! are no local time zones.

const std = @import("std");
const vm_mod = @import("../vm.zig");
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");

pub fn module(vm: *VM) *Table {
    return stdlib.makeModule(vm, &.{
        .{ .name = "now", .f = timeNow },
        .{ .name = "utc", .f = timeUtc },
        .{ .name = "from_utc", .f = timeFromUtc },
        .{ .name = "http_date", .f = timeHttpDate },
        .{ .name = "parse_http_date", .f = timeParseHttpDate },
        .{ .name = "iso", .f = timeIso },
        .{ .name = "parse_iso", .f = timeParseIso },
    });
}

// ------------------------------------------------------------ calendar

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// days_from_civil); month 1..12, day may run past the month.
pub fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i64, month: i64, day: i64 };

pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0), .month = month, .day = day };
}

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn daysInMonth(y: i64, m: i64) i64 {
    return switch (m) {
        2 => if (isLeap(y)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// A moment broken into its UTC fields.
const Broken = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    ms: i64,
    weekday: i64,
    yday: i64,
};

fn breakDown(t: f64) Broken {
    var secs: i64 = @intFromFloat(@floor(t));
    var ms: i64 = @intFromFloat(@round((t - @floor(t)) * 1000));
    if (ms >= 1000) {
        secs += 1;
        ms -= 1000;
    }
    const days = @divFloor(secs, 86400);
    const rem = @mod(secs, 86400);
    const c = civilFromDays(days);
    return .{
        .year = c.year,
        .month = c.month,
        .day = c.day,
        .hour = @divFloor(rem, 3600),
        .minute = @divFloor(@mod(rem, 3600), 60),
        .second = @mod(rem, 60),
        .ms = ms,
        .weekday = @mod(days + 4, 7),
        .yday = days - daysFromCivil(c.year, 1, 1) + 1,
    };
}

/// Seconds since the epoch, as an int when ms is 0.
fn secondsValue(secs: i64, frac: f64) Value {
    if (frac == 0) return .{ .int = secs };
    return .{ .float = @as(f64, @floatFromInt(secs)) + frac };
}

fn argTime(th: *Thread, args: []Value) Error!f64 {
    const t = try api.argNumber(th, args, 0, "t");
    if (!std.math.isFinite(t) or @abs(t) > 253402300799) return th.vm.raise("time out of range: {d}", .{t});
    return t;
}

// ------------------------------------------------------------ natives

fn timeNow(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const now = std.Io.Clock.now(.real, th.vm.io);
    const ms = @divFloor(now.nanoseconds, 1_000_000);
    return .{ .float = @as(f64, @floatFromInt(ms)) / 1000 };
}

fn timeUtc(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const b = breakDown(try argTime(th, args));
    const t = vm.newTable(0, 9);
    inline for (.{ "year", "month", "day", "hour", "minute", "second", "ms", "weekday", "yday" }) |name| {
        t.set(vm.gpa, vm.str(name), .{ .int = @field(b, name) });
    }
    return .{ .table = t };
}

fn field(th: *Thread, t: *Table, name: []const u8, def: ?i64) Error!f64 {
    const v = t.getName(name);
    if (v == .null) {
        if (def) |d| return @floatFromInt(d);
        return th.vm.raise("from_utc: {s} is required", .{name});
    }
    if (!v.isNumber()) return th.vm.raise("from_utc: {s} must be a number, got {s}", .{ name, v.typeName() });
    return v.asNumber();
}

fn timeFromUtc(th: *Thread, args: []Value) Error!Value {
    const t = try api.argTable(th, args, 0, "fields");
    const year: i64 = @intFromFloat(try field(th, t, "year", null));
    const month0: i64 = @as(i64, @intFromFloat(try field(th, t, "month", 1))) - 1;
    const days = daysFromCivil(year + @divFloor(month0, 12), @mod(month0, 12) + 1, 1) +
        @as(i64, @intFromFloat(try field(th, t, "day", 1))) - 1;
    const day_secs = (try field(th, t, "hour", 0)) * 3600 + (try field(th, t, "minute", 0)) * 60 +
        (try field(th, t, "second", 0)) + (try field(th, t, "ms", 0)) / 1000;
    const whole = @floor(day_secs);
    return secondsValue(days * 86400 + @as(i64, @intFromFloat(whole)), day_secs - whole);
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn timeHttpDate(th: *Thread, args: []Value) Error!Value {
    const b = breakDown(@floor(try argTime(th, args)));
    if (b.year < 0 or b.year > 9999) return th.vm.raise("http_date: year {d} out of range", .{b.year});
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[@intCast(b.weekday)], @as(u64, @intCast(b.day)), month_names[@intCast(b.month - 1)],
        @as(u64, @intCast(b.year)),     @as(u64, @intCast(b.hour)), @as(u64, @intCast(b.minute)),
        @as(u64, @intCast(b.second)),
    }) catch unreachable;
    return th.vm.str(s);
}

fn timeIso(th: *Thread, args: []Value) Error!Value {
    const b = breakDown(try argTime(th, args));
    if (b.year < 0 or b.year > 9999) return th.vm.raise("iso: year {d} out of range", .{b.year});
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(b.year)), @as(u64, @intCast(b.month)),  @as(u64, @intCast(b.day)),
        @as(u64, @intCast(b.hour)), @as(u64, @intCast(b.minute)), @as(u64, @intCast(b.second)),
    }) catch unreachable;
    if (b.ms != 0) w.print(".{d:0>3}", .{@as(u64, @intCast(b.ms))}) catch unreachable;
    w.writeByte('Z') catch unreachable;
    return th.vm.str(w.buffered());
}

// ------------------------------------------------------------ parsing

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn done(c: *const Cursor) bool {
        return c.i >= c.s.len;
    }

    fn peek(c: *const Cursor) ?u8 {
        return if (c.i < c.s.len) c.s[c.i] else null;
    }

    fn eat(c: *Cursor, ch: u8) bool {
        if (c.peek() == ch) {
            c.i += 1;
            return true;
        }
        return false;
    }

    fn spaces(c: *Cursor) void {
        while (c.peek() == ' ') c.i += 1;
    }

    /// Exactly n digits.
    fn digits(c: *Cursor, n: usize) ?i64 {
        if (c.i + n > c.s.len) return null;
        var v: i64 = 0;
        for (c.s[c.i .. c.i + n]) |ch| {
            if (!std.ascii.isDigit(ch)) return null;
            v = v * 10 + (ch - '0');
        }
        c.i += n;
        return v;
    }

    /// One or two digits (asctime pads the day with a space).
    fn shortNumber(c: *Cursor) ?i64 {
        const first = c.digits(1) orelse return null;
        if (c.peek()) |ch| if (std.ascii.isDigit(ch)) {
            c.i += 1;
            return first * 10 + (ch - '0');
        };
        return first;
    }

    fn word(c: *Cursor) []const u8 {
        const start = c.i;
        while (c.peek()) |ch| {
            if (!std.ascii.isAlphabetic(ch)) break;
            c.i += 1;
        }
        return c.s[start..c.i];
    }

    fn month(c: *Cursor) ?i64 {
        const w = c.word();
        if (w.len != 3) return null;
        for (month_names, 1..) |m, i| if (std.mem.eql(u8, m, w)) return @intCast(i);
        return null;
    }

    fn clock(c: *Cursor) ?i64 {
        const h = c.digits(2) orelse return null;
        if (!c.eat(':')) return null;
        const m = c.digits(2) orelse return null;
        if (!c.eat(':')) return null;
        const s = c.digits(2) orelse return null;
        if (h > 23 or m > 59 or s > 60) return null;
        return h * 3600 + m * 60 + @min(s, 59);
    }
};

fn dateSeconds(year: i64, month: i64, day: i64) ?i64 {
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    return daysFromCivil(year, month, day) * 86400;
}

fn parseHttpDate(s: []const u8) ?i64 {
    var c: Cursor = .{ .s = std.mem.trim(u8, s, " \t") };
    const weekday = c.word();
    if (weekday.len < 3) return null;
    if (c.eat(',')) {
        c.spaces();
        if (weekday.len == 3) {
            // RFC 1123: Sun, 06 Nov 1994 08:49:37 GMT
            const day = c.digits(2) orelse return null;
            if (!c.eat(' ')) return null;
            const month = c.month() orelse return null;
            if (!c.eat(' ')) return null;
            const year = c.digits(4) orelse return null;
            if (!c.eat(' ')) return null;
            const secs = c.clock() orelse return null;
            if (!c.eat(' ') or !std.mem.eql(u8, c.word(), "GMT") or !c.done()) return null;
            return (dateSeconds(year, month, day) orelse return null) + secs;
        }
        // RFC 850: Sunday, 06-Nov-94 08:49:37 GMT
        const day = c.digits(2) orelse return null;
        if (!c.eat('-')) return null;
        const month = c.month() orelse return null;
        if (!c.eat('-')) return null;
        const yy = c.digits(2) orelse return null;
        if (!c.eat(' ')) return null;
        const secs = c.clock() orelse return null;
        if (!c.eat(' ') or !std.mem.eql(u8, c.word(), "GMT") or !c.done()) return null;
        const year = if (yy < 70) 2000 + yy else 1900 + yy;
        return (dateSeconds(year, month, day) orelse return null) + secs;
    }
    // asctime: Sun Nov  6 08:49:37 1994
    if (weekday.len != 3 or !c.eat(' ')) return null;
    const month = c.month() orelse return null;
    c.spaces();
    const day = c.shortNumber() orelse return null;
    if (!c.eat(' ')) return null;
    const secs = c.clock() orelse return null;
    if (!c.eat(' ')) return null;
    const year = c.digits(4) orelse return null;
    if (!c.done()) return null;
    return (dateSeconds(year, month, day) orelse return null) + secs;
}

fn timeParseHttpDate(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    return if (parseHttpDate(s)) |t| .{ .int = t } else .null;
}

const Iso = struct { secs: i64, frac: f64 };

fn parseIso(s: []const u8) ?Iso {
    var c: Cursor = .{ .s = std.mem.trim(u8, s, " \t") };
    const year = c.digits(4) orelse return null;
    if (!c.eat('-')) return null;
    const month = c.digits(2) orelse return null;
    if (!c.eat('-')) return null;
    const day = c.digits(2) orelse return null;
    var secs = dateSeconds(year, month, day) orelse return null;
    var frac: f64 = 0;
    if (c.done()) return .{ .secs = secs, .frac = 0 };
    if (!(c.eat('T') or c.eat('t') or c.eat(' '))) return null;
    const h = c.digits(2) orelse return null;
    if (!c.eat(':')) return null;
    const m = c.digits(2) orelse return null;
    var sec: i64 = 0;
    if (c.eat(':')) {
        sec = c.digits(2) orelse return null;
        if (c.eat('.') or c.eat(',')) {
            var scale: f64 = 0.1;
            const start = c.i;
            while (c.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                frac += @as(f64, @floatFromInt(ch - '0')) * scale;
                scale /= 10;
                c.i += 1;
            }
            if (c.i == start) return null;
        }
    }
    if (h > 23 or m > 59 or sec > 60) return null;
    secs += h * 3600 + m * 60 + @min(sec, 59);
    if (c.eat('Z') or c.eat('z') or c.done()) {
        // UTC
    } else {
        const sign: i64 = if (c.eat('+')) 1 else if (c.eat('-')) -1 else return null;
        const oh = c.digits(2) orelse return null;
        var om: i64 = 0;
        if (c.eat(':')) {
            om = c.digits(2) orelse return null;
        } else if (!c.done()) {
            om = c.digits(2) orelse return null;
        }
        if (oh > 23 or om > 59) return null;
        secs -= sign * (oh * 3600 + om * 60);
    }
    if (!c.done()) return null;
    return .{ .secs = secs, .frac = frac };
}

fn timeParseIso(th: *Thread, args: []Value) Error!Value {
    const s = try api.argString(th, args, 0, "str");
    const r = parseIso(s) orelse return .null;
    return secondsValue(r.secs, r.frac);
}
