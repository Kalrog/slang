//! A bundled executable: a slang runtime with a payload (format.zig)
//! appended, followed by a 32-byte trailer that locates it:
//!
//!   "SLGTRAIL", u64 payload offset, u64 payload length, u64 0
//!
//! On macOS the trailer sits right before the code signature, which has to
//! stay last; elsewhere it ends the file. At startup the runtime maps its
//! own file and looks for the trailer (open); `slang build` writes it
//! (assemble).

const std = @import("std");
const builtin = @import("builtin");
const format = @import("format.zig");
const macho = @import("macho.zig");

pub const trailer_magic = "SLGTRAIL";
const trailer_len = 32;

pub const Signing = enum {
    /// sign ad hoc (macOS; nothing elsewhere)
    adhoc,
    /// leave it unsigned, prepared for `codesign` (macOS)
    external,
};

/// The executable base (a slang runtime) with payload appended; owned by the
/// caller. A signed Mach-O base loses its signature and is signed again as
/// signing says, under identifier.
pub fn assemble(gpa: std.mem.Allocator, base: []const u8, payload: []const u8, identifier: []const u8, signing: Signing) ![]u8 {
    if (find(base) != null) return error.AlreadyBundled;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, base);
    const is_macho = macho.isMachO(base);
    if (is_macho) out.shrinkRetainingCapacity(try macho.stripSignature(out.items));
    while (out.items.len % 16 != 0) try out.append(gpa, 0);
    const payload_off = out.items.len;
    try out.appendSlice(gpa, payload);
    while (out.items.len % 16 != 0) try out.append(gpa, 0);
    var trailer: [trailer_len]u8 = @splat(0);
    @memcpy(trailer[0..8], trailer_magic);
    std.mem.writeInt(u64, trailer[8..16], payload_off, .little);
    std.mem.writeInt(u64, trailer[16..24], payload.len, .little);
    try out.appendSlice(gpa, &trailer);
    if (is_macho) switch (signing) {
        .adhoc => try macho.signAdHoc(gpa, &out, identifier),
        // codesign wants __LINKEDIT to reach the end of the file
        .external => try macho.extendLinkedit(out.items, out.items.len),
    };
    return out.toOwnedSlice(gpa);
}

/// The payload of a trailer ending at end, if there is one.
fn trailerAt(image: []const u8, end: usize) ?[]const u8 {
    if (end < trailer_len or end > image.len) return null;
    const t = image[end - trailer_len .. end];
    if (!std.mem.eql(u8, t[0..8], trailer_magic)) return null;
    const off = std.mem.readInt(u64, t[8..16], .little);
    const len = std.mem.readInt(u64, t[16..24], .little);
    if (off > end - trailer_len or len > end - trailer_len - off) return null;
    return image[@intCast(off)..][0..@intCast(len)];
}

/// The payload of a bundled executable image, or null.
pub fn find(image: []const u8) ?[]const u8 {
    if (trailerAt(image, image.len)) |p| return p;
    // signed: right before the signature (codesign may leave padding)
    const sig: usize = @intCast(macho.signatureOffset(image) orelse return null);
    var end = sig;
    while (end + 4096 > sig and end >= trailer_len) : (end -= 16) {
        if (trailerAt(image, end)) |p| return p;
    }
    return null;
}

/// The payload of the running executable, opened once (see open).
pub const Bundle = struct {
    index: format.Index,
    /// The executable's directory: where external entries are.
    exe_dir: []const u8,

    pub const Hit = union(enum) {
        file: format.Entry,
        dir,
    };

    /// What a relative path names in the bundle: an asset file (maybe
    /// external), a directory of assets, or nothing.
    pub fn resolve(b: *const Bundle, path: []const u8) ?Hit {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const name = format.normalize(path, &buf) orelse return null;
        if (b.index.lookup(.asset, name)) |e| return .{ .file = e };
        if (name.len == 0 or b.index.isDir(name)) return .dir;
        return null;
    }

    /// Appends the names directly under a bundled directory to out; false
    /// when path is not one.
    pub fn list(b: *const Bundle, gpa: std.mem.Allocator, path: []const u8, out: *std.ArrayList([]const u8)) !bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = format.normalize(path, &buf) orelse return false;
        if (dir.len > 0 and !b.index.isDir(dir)) return false;
        var it = b.index.children(dir);
        while (it.next()) |name| try out.append(gpa, name);
        return true;
    }

    /// Where an external entry is on disk (owned by the caller).
    pub fn diskPath(b: *const Bundle, gpa: std.mem.Allocator, e: format.Entry) ![]u8 {
        return std.fs.path.join(gpa, &.{ b.exe_dir, e.name });
    }

    /// The contents of an entry (owned by the caller).
    pub fn read(b: *const Bundle, gpa: std.mem.Allocator, io: std.Io, e: format.Entry) ![]u8 {
        if (e.external()) {
            const path = try b.diskPath(gpa, e);
            defer gpa.free(path);
            return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        }
        return switch (e.encoding) {
            .raw => gpa.dupe(u8, e.data),
            .gzip => format.gunzip(gpa, e.data, e.raw_len),
        };
    }
};

/// The running executable's bundle, or null when it has none.
pub var current: ?*Bundle = null;

/// What a relative path names in the running executable's bundle, if it
/// has one (see Bundle.resolve).
pub fn resolve(path: []const u8) ?Bundle.Hit {
    const b = current orelse return null;
    return b.resolve(path);
}

/// Looks for a payload in the running executable (mapped, never copied) and
/// makes it current. An executable without one costs a map and a look at
/// its end. The mapping of one with a payload stays for the process's life.
pub fn open(gpa: std.mem.Allocator, io: std.Io) !?*Bundle {
    if (current) |b| return b;
    // a WebAssembly VM has no executable file of its own
    if (comptime builtin.cpu.arch.isWasm()) return null;
    const path = std.process.executablePathAlloc(io, gpa) catch return null;
    defer gpa.free(path);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const len = file.length(io) catch return null;
    if (len < trailer_len) return null;
    const map = std.posix.mmap(null, @intCast(len), .{ .READ = true }, .{ .TYPE = .PRIVATE }, file.handle, 0) catch return null;
    const payload = find(map) orelse {
        std.posix.munmap(map);
        return null;
    };
    const index = format.Index.parse(payload) catch |e| {
        std.posix.munmap(map);
        return e;
    };
    const b = try gpa.create(Bundle);
    b.* = .{
        .index = index,
        .exe_dir = try gpa.dupe(u8, std.fs.path.dirname(path) orelse "."),
    };
    current = b;
    return b;
}

test "assemble and find" {
    const gpa = std.testing.allocator;
    const plain = try assemble(gpa, "\x7fELF runtime", "PAYLOAD", "app", .adhoc);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("PAYLOAD", find(plain).?);
    try std.testing.expect(find("\x7fELF runtime") == null);
    try std.testing.expectError(error.AlreadyBundled, assemble(gpa, plain, "x", "app", .adhoc));
}
