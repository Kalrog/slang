//! The debugger's one connection: listen on 127.0.0.1:port, accept the
//! editor, then read, write and see whether something has arrived. BSD
//! sockets on POSIX, Winsock on Windows.

const std = @import("std");
const builtin = @import("builtin");

const windows = builtin.os.tag == .windows;

const win = struct {
    const SOCKET = usize;
    const invalid: SOCKET = ~@as(SOCKET, 0);
    const AF_INET: c_int = 2;
    const SOCK_STREAM: c_int = 1;
    const SOL_SOCKET: c_int = 0xffff;
    const SO_REUSEADDR: c_int = 4;
    const POLLRDNORM: i16 = 0x0100;
    const sockaddr_in = extern struct {
        family: u16 = AF_INET,
        port: u16,
        addr: u32,
        zero: [8]u8 = @splat(0),
    };
    const WSAPOLLFD = extern struct { fd: SOCKET, events: i16, revents: i16 };
    extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
    extern "ws2_32" fn socket(af: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn setsockopt(s: SOCKET, level: c_int, name: c_int, value: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn bind(s: SOCKET, addr: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(s: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(s: SOCKET, addr: ?*anyopaque, len: ?*c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAPoll(fds: [*]WSAPOLLFD, n: u32, timeout: c_int) callconv(.winapi) c_int;
};

const posix = struct {
    extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    extern "c" fn close(fd: c_int) c_int;
};

pub const Socket = struct {
    handle: if (windows) win.SOCKET else c_int,

    /// Listens on 127.0.0.1:port and waits for one connection. waiting()
    /// is called once listening, before accept blocks.
    pub fn accept(port: u16, waiting: anytype) !Socket {
        if (windows) {
            var data: [512]u8 = undefined;
            if (win.WSAStartup(0x0202, &data) != 0) return error.SocketFailed;
            const l = win.socket(win.AF_INET, win.SOCK_STREAM, 0);
            if (l == win.invalid) return error.SocketFailed;
            defer _ = win.closesocket(l);
            const one: c_int = 1;
            _ = win.setsockopt(l, win.SOL_SOCKET, win.SO_REUSEADDR, &one, @sizeOf(c_int));
            const addr: win.sockaddr_in = .{
                .port = std.mem.nativeToBig(u16, port),
                .addr = std.mem.nativeToBig(u32, 0x7f000001),
            };
            if (win.bind(l, &addr, @sizeOf(win.sockaddr_in)) != 0) return error.BindFailed;
            if (win.listen(l, 1) != 0) return error.ListenFailed;
            waiting.call();
            const s = win.accept(l, null, null);
            if (s == win.invalid) return error.AcceptFailed;
            return .{ .handle = s };
        }
        const l = posix.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (l < 0) return error.SocketFailed;
        defer _ = posix.close(l);
        const one: c_int = 1;
        _ = std.c.setsockopt(l, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));
        var addr: std.c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (std.c.bind(l, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
        if (std.c.listen(l, 1) != 0) return error.ListenFailed;
        waiting.call();
        const s = std.c.accept(l, null, null);
        if (s < 0) return error.AcceptFailed;
        return .{ .handle = s };
    }

    /// Whether something can be read without blocking.
    pub fn readable(s: Socket) bool {
        if (windows) {
            var fds = [_]win.WSAPOLLFD{.{ .fd = s.handle, .events = win.POLLRDNORM, .revents = 0 }};
            return win.WSAPoll(&fds, 1, 0) > 0;
        }
        var fds = [_]std.c.pollfd{.{ .fd = s.handle, .events = std.c.POLL.IN, .revents = 0 }};
        return std.c.poll(&fds, 1, 0) > 0;
    }

    /// Bytes read into buf; 0 or less when the connection is gone.
    pub fn read(s: Socket, buf: []u8) isize {
        if (windows) return win.recv(s.handle, buf.ptr, @intCast(buf.len), 0);
        return std.c.read(s.handle, buf.ptr, buf.len);
    }

    /// Bytes written; 0 or less when the connection is gone.
    pub fn write(s: Socket, bytes: []const u8) isize {
        if (windows) return win.send(s.handle, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(c_int))), 0);
        return std.c.write(s.handle, bytes.ptr, bytes.len);
    }

    pub fn close(s: Socket) void {
        if (windows) {
            _ = win.closesocket(s.handle);
        } else {
            _ = posix.close(s.handle);
        }
    }
};
