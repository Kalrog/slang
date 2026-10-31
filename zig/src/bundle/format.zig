//! The bundle payload that `slang build` appends to an executable: the
//! program's modules (bytecode) and its asset files, each stored raw or
//! gzipped. Little endian throughout; offsets are relative to the start of
//! the payload.
//!
//!   header  32 bytes: "SLGBNDL1", u32 version, u32 count, u64 index_off, u64 0
//!   data    the entries' bytes
//!   index   count records of 48 bytes, sorted by (kind, name), then the names:
//!           u8 kind, u8 encoding, u8 flags, u8 0, u32 name_len, u64 name_off,
//!           u64 offset, u64 stored_len, u64 raw_len, i64 mtime (seconds)
//!
//! Sorted records make a lookup a binary search; directories are implicit
//! (a name "public/app.css" makes "public" a directory).

const std = @import("std");
const flate = std.compress.flate;

pub const magic = "SLGBNDL1";
pub const version: u32 = 1;
const header_len = 32;
const record_len = 48;

pub const Kind = enum(u8) { module = 0, asset = 1 };
pub const Encoding = enum(u8) { raw = 0, gzip = 1 };
/// The file is not in the payload but next to the executable, at its name
/// (a `slang build --dir` asset).
pub const flag_external: u8 = 1;

/// The name of the entry module (the program itself).
pub const main_module = "<main>";

pub const Entry = struct {
    kind: Kind,
    name: []const u8,
    encoding: Encoding = .raw,
    flags: u8 = 0,
    /// The stored bytes (gzip data for .gzip, empty for external entries).
    data: []const u8,
    /// The length of the file itself.
    raw_len: u64,
    mtime: i64 = 0,

    pub fn external(e: Entry) bool {
        return e.flags & flag_external != 0;
    }
};

fn entryLess(_: void, a: Entry, b: Entry) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return std.mem.lessThan(u8, a.name, b.name);
}

pub const AddOptions = struct {
    /// Gzip the data, kept only when it saves at least min_gain of it.
    compress: bool = false,
    min_gain: f64 = 0.10,
    external: bool = false,
    mtime: i64 = 0,
};

/// Collects entries and writes the payload.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        for (w.entries.items) |e| {
            w.gpa.free(e.name);
            w.gpa.free(e.data);
        }
        w.entries.deinit(w.gpa);
    }

    /// Adds a copy of data under name (external entries store no data) and
    /// returns the entry as stored. A name added twice is an error.
    pub fn add(w: *Writer, kind: Kind, name: []const u8, data: []const u8, opts: AddOptions) !Entry {
        for (w.entries.items) |e| {
            if (e.kind == kind and std.mem.eql(u8, e.name, name)) return error.DuplicateEntry;
        }
        var e: Entry = .{
            .kind = kind,
            .name = try w.gpa.dupe(u8, name),
            .data = &.{},
            .raw_len = data.len,
            .mtime = opts.mtime,
            .flags = if (opts.external) flag_external else 0,
        };
        errdefer w.gpa.free(e.name);
        if (!opts.external) {
            const packed_data = if (opts.compress and data.len >= 64) try gzip(w.gpa, data) else null;
            const keep = if (packed_data) |p|
                @as(f64, @floatFromInt(p.len)) <= @as(f64, @floatFromInt(data.len)) * (1.0 - opts.min_gain)
            else
                false;
            if (keep) {
                e.data = packed_data.?;
                e.encoding = .gzip;
            } else {
                if (packed_data) |p| w.gpa.free(p);
                e.data = try w.gpa.dupe(u8, data);
            }
        }
        try w.entries.append(w.gpa, e);
        return e;
    }

    /// The payload bytes (owned by the caller).
    pub fn finish(w: *Writer) ![]u8 {
        const entries = w.entries.items;
        std.mem.sort(Entry, entries, {}, entryLess);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(w.gpa);
        try out.appendNTimes(w.gpa, 0, header_len);
        const offsets = try w.gpa.alloc(u64, entries.len);
        defer w.gpa.free(offsets);
        for (entries, 0..) |e, i| {
            offsets[i] = out.items.len;
            try out.appendSlice(w.gpa, e.data);
        }
        const index_off = out.items.len;
        var name_off: u64 = index_off + entries.len * record_len;
        for (entries, 0..) |e, i| {
            var rec: [record_len]u8 = @splat(0);
            rec[0] = @intFromEnum(e.kind);
            rec[1] = @intFromEnum(e.encoding);
            rec[2] = e.flags;
            std.mem.writeInt(u32, rec[4..8], @intCast(e.name.len), .little);
            std.mem.writeInt(u64, rec[8..16], name_off, .little);
            std.mem.writeInt(u64, rec[16..24], offsets[i], .little);
            std.mem.writeInt(u64, rec[24..32], e.data.len, .little);
            std.mem.writeInt(u64, rec[32..40], e.raw_len, .little);
            std.mem.writeInt(i64, rec[40..48], e.mtime, .little);
            try out.appendSlice(w.gpa, &rec);
            name_off += e.name.len;
        }
        for (entries) |e| try out.appendSlice(w.gpa, e.name);
        const h = out.items[0..header_len];
        @memcpy(h[0..8], magic);
        std.mem.writeInt(u32, h[8..12], version, .little);
        std.mem.writeInt(u32, h[12..16], @intCast(entries.len), .little);
        std.mem.writeInt(u64, h[16..24], index_off, .little);
        return out.toOwnedSlice(w.gpa);
    }
};

/// A parsed payload; entries point into its bytes.
pub const Index = struct {
    payload: []const u8,
    count: usize,
    index_off: usize,

    pub fn parse(payload: []const u8) !Index {
        if (payload.len < header_len or !std.mem.eql(u8, payload[0..8], magic)) return error.NotABundle;
        if (std.mem.readInt(u32, payload[8..12], .little) != version) return error.UnsupportedVersion;
        const count = std.mem.readInt(u32, payload[12..16], .little);
        const index_off = std.mem.readInt(u64, payload[16..24], .little);
        if (index_off > payload.len or (payload.len - index_off) / record_len < count) return error.Corrupt;
        const idx: Index = .{ .payload = payload, .count = count, .index_off = @intCast(index_off) };
        for (0..count) |i| _ = try idx.entryChecked(i);
        return idx;
    }

    fn entryChecked(idx: Index, i: usize) !Entry {
        const rec = idx.payload[idx.index_off + i * record_len ..][0..record_len];
        const name_len = std.mem.readInt(u32, rec[4..8], .little);
        const name_off = std.mem.readInt(u64, rec[8..16], .little);
        const offset = std.mem.readInt(u64, rec[16..24], .little);
        const stored = std.mem.readInt(u64, rec[24..32], .little);
        if (rec[0] > 1 or rec[1] > 1) return error.Corrupt;
        if (name_off > idx.payload.len or idx.payload.len - name_off < name_len) return error.Corrupt;
        if (offset > idx.payload.len or idx.payload.len - offset < stored) return error.Corrupt;
        return .{
            .kind = @enumFromInt(rec[0]),
            .encoding = @enumFromInt(rec[1]),
            .flags = rec[2],
            .name = idx.payload[name_off..][0..name_len],
            .data = idx.payload[offset..][0..stored],
            .raw_len = std.mem.readInt(u64, rec[32..40], .little),
            .mtime = std.mem.readInt(i64, rec[40..48], .little),
        };
    }

    pub fn entry(idx: Index, i: usize) Entry {
        return idx.entryChecked(i) catch unreachable; // checked by parse
    }

    /// The first index of kind whose name is not less than name.
    fn lowerBound(idx: Index, kind: Kind, name: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = idx.count;
        const probe: Entry = .{ .kind = kind, .name = name, .data = &.{}, .raw_len = 0 };
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (entryLess({}, idx.entry(mid), probe)) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    pub fn lookup(idx: Index, kind: Kind, name: []const u8) ?Entry {
        const i = idx.lowerBound(kind, name);
        if (i >= idx.count) return null;
        const e = idx.entry(i);
        return if (e.kind == kind and std.mem.eql(u8, e.name, name)) e else null;
    }

    /// Whether some asset lies under dir (a normalized path; "" is the root).
    pub fn isDir(idx: Index, dir: []const u8) bool {
        var it = idx.children(dir);
        return it.next() != null;
    }

    /// The names directly under dir, each once, in order.
    pub fn children(idx: Index, dir: []const u8) ChildIterator {
        return .{ .idx = idx, .dir = dir, .i = if (dir.len == 0) idx.lowerBound(.asset, "") else idx.lowerBound(.asset, dir) };
    }

    pub const ChildIterator = struct {
        idx: Index,
        dir: []const u8,
        i: usize,
        last: []const u8 = "",

        pub fn next(it: *ChildIterator) ?[]const u8 {
            while (it.i < it.idx.count) : (it.i += 1) {
                const e = it.idx.entry(it.i);
                if (e.kind != .asset) return null;
                var rest = e.name;
                if (it.dir.len > 0) {
                    if (!std.mem.startsWith(u8, e.name, it.dir)) return null;
                    if (e.name.len <= it.dir.len or e.name[it.dir.len] != '/') continue;
                    rest = e.name[it.dir.len + 1 ..];
                }
                const child = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
                if (std.mem.eql(u8, child, it.last)) continue;
                it.last = child;
                it.i += 1;
                return child;
            }
            return null;
        }
    };
};

/// A relative path in bundle form ("a/b"): "." and empty segments dropped,
/// ".." resolved. Null for absolute paths and paths that leave the root.
pub fn normalize(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0 or path[0] == '/' or path.len > buf.len) return null;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (n == 0) return null;
            n = if (std.mem.lastIndexOfScalar(u8, buf[0..n], '/')) |s| s else 0;
            continue;
        }
        if (n > 0) {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n..][0..seg.len], seg);
        n += seg.len;
    }
    return buf[0..n];
}

/// Gzip data (reproducible: no name, mtime 0).
pub fn gzip(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    // the compressor wants room in its output from the start
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = try flate.Compress.init(&out.writer, window, .gzip, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

/// The data of a gzip stream; its length must be raw_len.
pub fn gunzip(gpa: std.mem.Allocator, data: []const u8, raw_len: u64) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var d = flate.Decompress.init(&in, .gzip, &.{});
    const out = try d.reader.allocRemaining(gpa, .limited(raw_len + 1));
    if (out.len != raw_len) {
        gpa.free(out);
        return error.Corrupt;
    }
    return out;
}

test "payload round trip, lookup and directories" {
    const gpa = std.testing.allocator;
    var w = Writer.init(gpa);
    defer w.deinit();
    const line = "body { color: red }\n";
    const text = line ++ line ++ line ++ line ++ line ++ line ++ line ++ line;
    _ = try w.add(.asset, "public/app.css", text, .{ .compress = true, .mtime = 7 });
    _ = try w.add(.asset, "public/img/a.png", "\x89PNG", .{ .compress = true });
    _ = try w.add(.asset, "data.txt", "hello", .{});
    _ = try w.add(.asset, "public2", "x", .{});
    _ = try w.add(.module, main_module, "SLANG...", .{});
    _ = try w.add(.module, "util/x", "SLANG.", .{});
    try std.testing.expectError(error.DuplicateEntry, w.add(.asset, "data.txt", "", .{}));
    const payload = try w.finish();
    defer gpa.free(payload);

    const idx = try Index.parse(payload);
    try std.testing.expectEqual(@as(usize, 6), idx.count);
    const css = idx.lookup(.asset, "public/app.css").?;
    try std.testing.expectEqual(Encoding.gzip, css.encoding);
    try std.testing.expectEqual(@as(i64, 7), css.mtime);
    const raw = try gunzip(gpa, css.data, css.raw_len);
    defer gpa.free(raw);
    try std.testing.expectEqualStrings(text, raw);
    // too small to gain: stored as is
    try std.testing.expectEqual(Encoding.raw, idx.lookup(.asset, "public/img/a.png").?.encoding);
    try std.testing.expectEqualStrings("SLANG.", idx.lookup(.module, "util/x").?.data);
    try std.testing.expect(idx.lookup(.module, "data.txt") == null);
    try std.testing.expect(idx.isDir("public"));
    try std.testing.expect(idx.isDir("public/img"));
    try std.testing.expect(!idx.isDir("data.txt"));
    try std.testing.expect(!idx.isDir("pub"));

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    var it = idx.children("");
    while (it.next()) |n| try names.print(gpa, "{s},", .{n});
    try std.testing.expectEqualStrings("data.txt,public,public2,", names.items);
    names.clearRetainingCapacity();
    it = idx.children("public");
    while (it.next()) |n| try names.print(gpa, "{s},", .{n});
    try std.testing.expectEqualStrings("app.css,img,", names.items);
}

test "normalize" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a/b", normalize("./a//b/", &buf).?);
    try std.testing.expectEqualStrings("b", normalize("a/../b", &buf).?);
    try std.testing.expectEqualStrings("", normalize(".", &buf).?);
    try std.testing.expect(normalize("/etc/passwd", &buf) == null);
    try std.testing.expect(normalize("../x", &buf) == null);
    try std.testing.expect(normalize("a/../../x", &buf) == null);
}
