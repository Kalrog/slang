//! Shared libraries, the same on every OS: dlopen and dlsym on POSIX,
//! LoadLibraryW and GetProcAddress on Windows. Used for native extensions
//! (loader.zig) and slang/ffi (ffilib.zig).

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

const win = struct {
    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    /// a library given by its path finds its own dependencies in its folder
    const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
};

const posix = struct {
    const RTLD_LAZY: c_int = 0x1;
    const RTLD_NOW: c_int = 0x2;
    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
    extern "c" fn dlclose(handle: *anyopaque) c_int;
    extern "c" fn dlerror() ?[*:0]const u8;
};

pub const Library = struct {
    handle: *anyopaque,

    pub const OpenError = error{ OutOfMemory, InvalidUtf8, FileNotFound };

    /// Opens the library at path. now: resolve every symbol at once
    /// (RTLD_NOW; Windows always does).
    pub fn open(gpa: std.mem.Allocator, path: []const u8, now: bool) OpenError!Library {
        if (windows) {
            const w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidUtf8,
            };
            defer gpa.free(w);
            // (the altered search path takes backslashes only; a bare name
            // like "kernel32.dll" is searched for as usual)
            var has_dir = false;
            for (w) |*c| {
                if (c.* == '/') c.* = '\\';
                if (c.* == '\\') has_dir = true;
            }
            const flags: u32 = if (has_dir) win.LOAD_WITH_ALTERED_SEARCH_PATH else 0;
            const h = win.LoadLibraryExW(w.ptr, null, flags) orelse return error.FileNotFound;
            return .{ .handle = h };
        }
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        const mode = if (now) posix.RTLD_NOW else posix.RTLD_LAZY;
        const h = posix.dlopen(z.ptr, mode) orelse return error.FileNotFound;
        return .{ .handle = h };
    }

    /// The program itself (the executable and, on POSIX, what it has loaded).
    pub fn self() ?Library {
        const h = if (windows) win.GetModuleHandleW(null) else posix.dlopen(null, posix.RTLD_LAZY);
        return if (h) |p| .{ .handle = p } else null;
    }

    /// The address of a symbol, or null.
    pub fn symbol(lib: Library, name: [*:0]const u8) ?*anyopaque {
        return if (windows) win.GetProcAddress(lib.handle, name) else posix.dlsym(lib.handle, name);
    }

    /// The symbol as a T (a function pointer type), or null.
    pub fn lookup(lib: Library, comptime T: type, name: [*:0]const u8) ?T {
        const p = lib.symbol(name) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    pub fn close(lib: Library) void {
        if (windows) {
            _ = win.FreeLibrary(lib.handle);
        } else {
            _ = posix.dlclose(lib.handle);
        }
    }
};

/// Why the last open failed, as the OS says it (dlerror; on Windows the
/// error code), or null.
pub fn lastError(buf: []u8) ?[]const u8 {
    if (windows) {
        const code = std.os.windows.GetLastError();
        return std.fmt.bufPrint(buf, "Windows error {d} ({t})", .{ @intFromEnum(code), code }) catch null;
    }
    const e = posix.dlerror() orelse return null;
    return std.mem.span(e);
}
