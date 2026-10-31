//! What `slang build` needs from Mach-O (64-bit, thin): taking the code
//! signature off an executable, growing __LINKEDIT over data appended to
//! it, and signing it again ad hoc (what the linker does on Apple silicon,
//! where unsigned code does not run).
//!
//! The signature is a SuperBlob holding one CodeDirectory: a SHA-256 hash of
//! every 4 KiB page of the file up to the signature. It must be the last
//! thing in the file and inside __LINKEDIT, so the payload goes before it.

const std = @import("std");

const MH_MAGIC_64: u32 = 0xfeedfacf;
const LC_SEGMENT_64: u32 = 0x19;
const LC_CODE_SIGNATURE: u32 = 0x1d;
const header_len = 32;

const CSMAGIC_EMBEDDED_SIGNATURE: u32 = 0xfade0cc0;
const CSMAGIC_CODEDIRECTORY: u32 = 0xfade0c02;
const CS_ADHOC: u32 = 0x2;
const CS_EXECSEG_MAIN_BINARY: u64 = 0x1;
const CS_HASHTYPE_SHA256: u8 = 2;
const page_shift = 12;
const page_size = 1 << page_shift;
const code_directory_len = 88;

pub fn isMachO(image: []const u8) bool {
    return image.len >= header_len and std.mem.readInt(u32, image[0..4], .little) == MH_MAGIC_64;
}

fn ncmds(image: []const u8) u32 {
    return std.mem.readInt(u32, image[16..20], .little);
}

fn sizeofcmds(image: []const u8) u32 {
    return std.mem.readInt(u32, image[20..24], .little);
}

const Command = struct { off: usize, cmd: u32, size: u32 };

const CommandIterator = struct {
    image: []const u8,
    left: u32,
    off: usize = header_len,

    fn next(it: *CommandIterator) !?Command {
        if (it.left == 0) return null;
        if (it.off + 8 > it.image.len) return error.BadMachO;
        const c: Command = .{
            .off = it.off,
            .cmd = std.mem.readInt(u32, it.image[it.off..][0..4], .little),
            .size = std.mem.readInt(u32, it.image[it.off + 4 ..][0..4], .little),
        };
        if (c.size < 8 or c.off + c.size > it.image.len) return error.BadMachO;
        it.off += c.size;
        it.left -= 1;
        return c;
    }
};

fn commands(image: []const u8) CommandIterator {
    return .{ .image = image, .left = ncmds(image) };
}

/// The offset of the load command of segment name, or null.
fn segment(image: []const u8, name: []const u8) !?usize {
    var it = commands(image);
    while (try it.next()) |c| {
        if (c.cmd != LC_SEGMENT_64) continue;
        const seg = std.mem.sliceTo(image[c.off + 8 ..][0..16], 0);
        if (std.mem.eql(u8, seg, name)) return c.off;
    }
    return null;
}

/// Where the code signature starts, or null for an unsigned image.
pub fn signatureOffset(image: []const u8) ?u64 {
    if (!isMachO(image)) return null;
    var it = commands(image);
    while (it.next() catch return null) |c| {
        if (c.cmd == LC_CODE_SIGNATURE) return std.mem.readInt(u32, image[c.off + 8 ..][0..4], .little);
    }
    return null;
}

/// Removes the code signature (its load command and its data at the end of
/// the file); returns the new length of the image.
pub fn stripSignature(image: []u8) !usize {
    var it = commands(image);
    while (try it.next()) |c| {
        if (c.cmd != LC_CODE_SIGNATURE) continue;
        const dataoff = std.mem.readInt(u32, image[c.off + 8 ..][0..4], .little);
        const datasize = std.mem.readInt(u32, image[c.off + 12 ..][0..4], .little);
        if (@as(u64, dataoff) + datasize > image.len) return error.BadMachO;
        // the commands after it move up over it
        const end = header_len + sizeofcmds(image);
        std.mem.copyForwards(u8, image[c.off .. end - c.size], image[c.off + c.size .. end]);
        @memset(image[end - c.size .. end], 0);
        std.mem.writeInt(u32, image[16..20], ncmds(image) - 1, .little);
        std.mem.writeInt(u32, image[20..24], sizeofcmds(image) - c.size, .little);
        try extendLinkedit(image[0..dataoff], dataoff);
        return dataoff;
    }
    return image.len;
}

/// Makes __LINKEDIT (the last segment) end at end, so that it covers data
/// appended to the image.
pub fn extendLinkedit(image: []u8, end: u64) !void {
    const off = (try segment(image, "__LINKEDIT")) orelse return error.BadMachO;
    const fileoff = std.mem.readInt(u64, image[off + 40 ..][0..8], .little);
    if (end < fileoff) return error.BadMachO;
    const filesize = end - fileoff;
    std.mem.writeInt(u64, image[off + 48 ..][0..8], filesize, .little);
    std.mem.writeInt(u64, image[off + 32 ..][0..8], std.mem.alignForward(u64, filesize, 0x4000), .little);
}

/// The space between the load commands and the first section's data.
fn headerRoom(image: []const u8) !u64 {
    var first: u64 = image.len;
    var it = commands(image);
    while (try it.next()) |c| {
        if (c.cmd != LC_SEGMENT_64) continue;
        const nsects = std.mem.readInt(u32, image[c.off + 64 ..][0..4], .little);
        for (0..nsects) |i| {
            const s = c.off + 72 + i * 80;
            if (s + 80 > image.len) return error.BadMachO;
            const offset = std.mem.readInt(u32, image[s + 48 ..][0..4], .little);
            const size = std.mem.readInt(u64, image[s + 40 ..][0..8], .little);
            if (offset != 0 and size != 0) first = @min(first, offset);
        }
    }
    return first - (header_len + sizeofcmds(image));
}

/// Signs an unsigned image ad hoc, in place: pads it to 16 bytes, adds the
/// code signature command, grows __LINKEDIT over the signature and appends
/// it. identifier names the code (the file name, as the linker does).
pub fn signAdHoc(gpa: std.mem.Allocator, image: *std.ArrayList(u8), identifier: []const u8) !void {
    if (!isMachO(image.items)) return error.BadMachO;
    if (signatureOffset(image.items) != null) return error.AlreadySigned;
    if (try headerRoom(image.items) < 16) return error.NoRoomForSignature;
    while (image.items.len % 16 != 0) try image.append(gpa, 0);

    const dataoff = image.items.len;
    if (dataoff > std.math.maxInt(u32)) return error.TooLarge;
    const slots = std.math.divCeil(usize, dataoff, page_size) catch unreachable;
    const hash_off = code_directory_len + identifier.len + 1;
    const cd_len = hash_off + slots * 32;
    const sig_len = 12 + 8 + cd_len;
    const datasize = std.mem.alignForward(usize, sig_len, 16);

    // the load command, and __LINKEDIT over the signature: both are part
    // of the first page, so they come before the hashing
    const lc = header_len + sizeofcmds(image.items);
    const items = image.items;
    std.mem.writeInt(u32, items[lc..][0..4], LC_CODE_SIGNATURE, .little);
    std.mem.writeInt(u32, items[lc + 4 ..][0..4], 16, .little);
    std.mem.writeInt(u32, items[lc + 8 ..][0..4], @intCast(dataoff), .little);
    std.mem.writeInt(u32, items[lc + 12 ..][0..4], @intCast(datasize), .little);
    std.mem.writeInt(u32, items[16..20], ncmds(items) + 1, .little);
    std.mem.writeInt(u32, items[20..24], sizeofcmds(items) + 16, .little);
    try extendLinkedit(items, dataoff + datasize);

    const text = (try segment(items, "__TEXT")) orelse return error.BadMachO;
    const text_off = std.mem.readInt(u64, items[text + 40 ..][0..8], .little);
    const text_size = std.mem.readInt(u64, items[text + 48 ..][0..8], .little);

    const sig = try gpa.alloc(u8, datasize);
    defer gpa.free(sig);
    @memset(sig, 0);
    // SuperBlob: magic, length, count, then {type 0 (CodeDirectory), offset}
    std.mem.writeInt(u32, sig[0..4], CSMAGIC_EMBEDDED_SIGNATURE, .big);
    std.mem.writeInt(u32, sig[4..8], @intCast(sig_len), .big);
    std.mem.writeInt(u32, sig[8..12], 1, .big);
    std.mem.writeInt(u32, sig[12..16], 0, .big);
    std.mem.writeInt(u32, sig[16..20], 20, .big);
    const cd = sig[20..][0..cd_len];
    std.mem.writeInt(u32, cd[0..4], CSMAGIC_CODEDIRECTORY, .big);
    std.mem.writeInt(u32, cd[4..8], @intCast(cd_len), .big);
    std.mem.writeInt(u32, cd[8..12], 0x20400, .big); // version (with exec segment fields)
    std.mem.writeInt(u32, cd[12..16], CS_ADHOC, .big);
    std.mem.writeInt(u32, cd[16..20], @intCast(hash_off), .big);
    std.mem.writeInt(u32, cd[20..24], code_directory_len, .big); // identifier offset
    std.mem.writeInt(u32, cd[24..28], 0, .big); // special slots
    std.mem.writeInt(u32, cd[28..32], @intCast(slots), .big);
    std.mem.writeInt(u32, cd[32..36], @intCast(dataoff), .big); // code limit
    cd[36] = 32; // hash size
    cd[37] = CS_HASHTYPE_SHA256;
    cd[38] = 0; // platform
    cd[39] = page_shift;
    // 40..64: spare2, scatter offset, team offset, spare3, code limit 64 (all 0)
    std.mem.writeInt(u64, cd[64..72], text_off, .big);
    std.mem.writeInt(u64, cd[72..80], text_size, .big);
    std.mem.writeInt(u64, cd[80..88], CS_EXECSEG_MAIN_BINARY, .big);
    @memcpy(cd[code_directory_len..][0..identifier.len], identifier);
    for (0..slots) |i| {
        const page = items[i * page_size .. @min(dataoff, (i + 1) * page_size)];
        std.crypto.hash.sha2.Sha256.hash(page, cd[hash_off + i * 32 ..][0..32], .{});
    }
    try image.appendSlice(gpa, sig);
}

/// A minimal image: header, __TEXT with one section, __LINKEDIT.
fn testImage(gpa: std.mem.Allocator) !std.ArrayList(u8) {
    var img: std.ArrayList(u8) = .empty;
    try img.appendNTimes(gpa, 0, 0x1000 + 64);
    const b = img.items;
    std.mem.writeInt(u32, b[0..4], MH_MAGIC_64, .little);
    std.mem.writeInt(u32, b[16..20], 2, .little);
    const text_size = 72 + 80;
    std.mem.writeInt(u32, b[20..24], text_size + 72, .little);
    // __TEXT at 32
    std.mem.writeInt(u32, b[32..36], LC_SEGMENT_64, .little);
    std.mem.writeInt(u32, b[36..40], text_size, .little);
    @memcpy(b[40..46], "__TEXT");
    std.mem.writeInt(u64, b[32 + 48 ..][0..8], 0x1000, .little); // filesize
    std.mem.writeInt(u32, b[32 + 64 ..][0..4], 1, .little); // nsects
    const s = 32 + 72;
    std.mem.writeInt(u64, b[s + 40 ..][0..8], 16, .little); // size
    std.mem.writeInt(u32, b[s + 48 ..][0..4], 0x800, .little); // offset
    // __LINKEDIT after it
    const l = 32 + text_size;
    std.mem.writeInt(u32, b[l..][0..4], LC_SEGMENT_64, .little);
    std.mem.writeInt(u32, b[l + 4 ..][0..4], 72, .little);
    @memcpy(b[l + 8 ..][0..10], "__LINKEDIT");
    std.mem.writeInt(u64, b[l + 40 ..][0..8], 0x1000, .little); // fileoff
    std.mem.writeInt(u64, b[l + 48 ..][0..8], 64, .little);
    return img;
}

test "sign, find, strip" {
    const gpa = std.testing.allocator;
    var img = try testImage(gpa);
    defer img.deinit(gpa);
    try img.appendSlice(gpa, "payload!");
    const unsigned_len = img.items.len;
    try signAdHoc(gpa, &img, "app");
    const off = signatureOffset(img.items).?;
    try std.testing.expectEqual(std.mem.alignForward(u64, unsigned_len, 16), off);
    try std.testing.expectEqual(@as(u32, 3), ncmds(img.items));
    // __LINKEDIT reaches the end of the file
    const l = (try segment(img.items, "__LINKEDIT")).?;
    try std.testing.expectEqual(@as(u64, img.items.len - 0x1000), std.mem.readInt(u64, img.items[l + 48 ..][0..8], .little));
    // the first page hash covers the patched header
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(img.items[0..page_size], &h, .{});
    const cd = img.items[off + 20 ..];
    const hash_off = std.mem.readInt(u32, cd[16..20], .big);
    try std.testing.expectEqualSlices(u8, &h, cd[hash_off..][0..32]);

    try std.testing.expectError(error.AlreadySigned, signAdHoc(gpa, &img, "app"));
    const n = try stripSignature(img.items);
    try std.testing.expectEqual(off, n);
    img.shrinkRetainingCapacity(n);
    try std.testing.expect(signatureOffset(img.items) == null);
    try std.testing.expectEqual(@as(u32, 2), ncmds(img.items));
}
