const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("../vm.zig");
const oom = root.oom;
const Value = root.Value;
const String = root.String;
const Table = root.Table;
const object = @import("object.zig");
const Object = object.Object;
const Closure = object.Closure;
const Upvalue = object.Upvalue;
const Userdata = object.Userdata;
const Proto = object.Proto;
const Thread = root.Thread;
const Error = root.Error;
const SlangError = root.SlangError;
const gc = @import("gc.zig");

pub const EmbeddedFile = struct {
    name: []const u8,
    data: []const u8,
};

const InternCtx = struct {
    pub fn hash(_: InternCtx, s: *String) u64 {
        return s.hash();
    }
    pub fn eql(_: InternCtx, a: *String, b: *String) bool {
        return a == b;
    }
};

const InternBytesCtx = struct {
    pub fn hash(_: InternBytesCtx, b: []const u8) u64 {
        return String.hashBytes(b);
    }
    pub fn eql(_: InternBytesCtx, b: []const u8, s: *String) bool {
        return s.eqlBytes(b);
    }
};

/// The state shared by all threads: globals, the package registry, the heap
/// and the standard streams.
pub const VM = struct {
    /// The VM's allocator: everything it allocates goes through the
    /// counting allocator so bytes_allocated is exact.
    gpa: Allocator,
    backing: Allocator,
    counting: gc.CountingAllocator,
    io: std.Io,
    globals: *Table,
    packages: *Table,
    main: *Thread,
    args: []const []const u8 = &.{},
    embedded: []const EmbeddedFile = &.{},
    stdout: std.Io.File.Writer,
    stdin: std.Io.File.Reader,
    stdout_buf: []u8,
    stdin_buf: []u8,
    /// The environment (null when embedded through the C API: libc getenv).
    env: ?*std.process.Environ.Map,
    /// Free slots of the reference registry (slang_ref).
    ref_free: std.ArrayList(i64) = .empty,
    next_ref: i64 = 1,
    /// Shared libraries opened for native extensions (never closed).
    libraries: std.ArrayList(std.DynLib) = .empty,

    /// All heap objects, for the collector.
    objects: ?*Object = null,
    strings: std.HashMapUnmanaged(*String, void, InternCtx, 80) = .empty,
    bytes_allocated: usize = 0,
    next_gc: usize = gc.initial_threshold,
    gc_running: bool = false,
    collections: usize = 0,
    /// Values kept alive by the C API (slang_ref).
    registry: *Table,

    /// Line starts of the string most recently passed to str.line_col
    /// (parsers call it once per token on the same buffer).
    line_cache_str: ?*String = null,
    line_cache: std.ArrayList(u32) = .empty,

    /// The pending error after a function returned error.Slang.
    err: ?SlangError = null,
    next_thread_id: u32 = 0,
    /// SLANG_TRACE: print every instruction to stderr.
    trace: bool = false,
    /// The sampling profiler, when one runs (see profile.zig).
    profiler: ?*root.Profiler = null,
    /// The debugger, when an editor debugs the program (see debug.zig).
    debugger: ?*root.Debugger = null,

    pub fn create(backing: Allocator, io: std.Io, env: ?*std.process.Environ.Map) *VM {
        const vm = backing.create(VM) catch oom();
        const out_buf = backing.alloc(u8, 1 << 16) catch oom();
        const in_buf = backing.alloc(u8, 1 << 16) catch oom();
        vm.* = .{
            .gpa = undefined,
            .backing = backing,
            .counting = .{ .backing = backing, .counter = &vm.bytes_allocated },
            .io = io,
            .globals = undefined,
            .packages = undefined,
            .main = undefined,
            .registry = undefined,
            // streaming: a positional writer rewrites offset 0 of a redirected file
            .stdout = std.Io.File.stdout().writerStreaming(io, out_buf),
            .stdin = std.Io.File.stdin().readerStreaming(io, in_buf),
            .stdout_buf = out_buf,
            .stdin_buf = in_buf,
            .env = env,
        };
        vm.gpa = vm.counting.allocator();
        vm.globals = vm.newTable(0, 64);
        vm.packages = vm.newTable(0, 4);
        vm.registry = vm.newTable(0, 0);
        vm.main = vm.newThread(null);
        vm.main.is_main = true;
        vm.main.status = .running;
        return vm;
    }

    pub fn destroy(vm: *VM) void {
        vm.flush();
        if (vm.profiler) |p| {
            p.finish();
            p.destroy();
        }
        gc.freeAll(vm);
        vm.strings.deinit(vm.gpa);
        vm.line_cache.deinit(vm.gpa);
        vm.ref_free.deinit(vm.gpa);
        vm.libraries.deinit(vm.gpa);
        if (vm.err) |*e| e.deinit(vm.gpa);
        vm.backing.free(vm.stdout_buf);
        vm.backing.free(vm.stdin_buf);
        vm.backing.destroy(vm);
    }

    pub fn out(vm: *VM) *std.Io.Writer {
        return &vm.stdout.interface;
    }

    pub fn flush(vm: *VM) void {
        vm.stdout.interface.flush() catch {};
    }

    // Errors.

    /// Records a slang error; the caller returns error.Slang.
    pub fn setError(vm: *VM, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrintSentinel(vm.gpa, fmt, args, 0) catch oom();
        vm.setErrorOwned(msg);
    }

    pub fn dupeZ(vm: *VM, bytes: []const u8) [:0]u8 {
        const z = vm.gpa.allocSentinel(u8, bytes.len, 0) catch oom();
        @memcpy(z, bytes);
        return z;
    }

    /// Makes an error value (an error table {message, location, stack} or
    /// any other value, rendered) the pending error; raise() and
    /// slang_raise use it.
    pub fn setErrorFromValue(vm: *VM, v: Value) void {
        if (v.asTable()) |t| {
            // the message for printing: the message field, or the table;
            // a value field (what did not fit) is shown after it
            const m = t.getName("message");
            const text = root.format.valueToOwned(vm.gpa, if (m == .null) v else m);
            defer vm.gpa.free(text);
            const carried = t.getName("value");
            var msg: []u8 = text;
            var joined: ?[]u8 = null;
            defer if (joined) |j| vm.gpa.free(j);
            if (m != .null and carried != .null) {
                const shown = root.format.valueToOwned(vm.gpa, carried);
                defer vm.gpa.free(shown);
                joined = std.fmt.allocPrint(vm.gpa, "{s}, got {s}", .{ text, shown }) catch oom();
                msg = joined.?;
            }
            var e: SlangError = .{ .message = vm.dupeZ(msg), .value = v };
            if (t.getName("location").asTable()) |loc| {
                e.loc = .{
                    .origin = root.format.valueToOwned(vm.gpa, loc.getName("origin")),
                    .line = @intCast(@max(0, loc.getName("line").asInt())),
                    .column = @intCast(@max(0, loc.getName("column").asInt())),
                };
            }
            if (t.getName("stack").asBytes()) |st| e.trace = vm.gpa.dupe(u8, st) catch oom();
            vm.setErrorFull(e);
            return;
        }
        const msg = root.format.valueToOwned(vm.gpa, v);
        defer vm.gpa.free(msg);
        vm.setErrorOwned(vm.dupeZ(msg));
    }

    pub fn setErrorOwned(vm: *VM, msg: [:0]u8) void {
        if (vm.err) |*e| e.deinit(vm.gpa);
        vm.err = .{ .message = msg };
    }

    pub fn setErrorFull(vm: *VM, e: SlangError) void {
        if (vm.err) |*old| old.deinit(vm.gpa);
        vm.err = e;
    }

    pub fn raise(vm: *VM, comptime fmt: []const u8, args: anytype) Error {
        vm.setError(fmt, args);
        return error.Slang;
    }

    pub fn raiseMsg(vm: *VM, msg: []const u8) Error {
        vm.setErrorOwned(vm.dupeZ(msg));
        return error.Slang;
    }

    /// Moves the pending error out of the VM.
    pub fn takeError(vm: *VM) SlangError {
        if (vm.err) |e| {
            vm.err = null;
            return e;
        }
        return .{ .message = vm.dupeZ("unknown error") };
    }

    /// Converts the pending error into the slang error table
    /// {message, location: {line, column, origin}, stack}.
    pub fn errorToValue(vm: *VM) Value {
        var e = vm.takeError();
        defer e.deinit(vm.gpa);
        if (e.value.asTable()) |raised| {
            // a raised table is the error itself; it gains where it was
            // raised unless it already says (a re-raise keeps the original)
            if (raised.getName("location") == .null) {
                if (e.loc) |l| {
                    const loc = vm.newTable(0, 3);
                    loc.set(vm.gpa, vm.str("line"), .{ .int = l.line });
                    loc.set(vm.gpa, vm.str("column"), .{ .int = l.column });
                    loc.set(vm.gpa, vm.str("origin"), vm.strValue(l.origin));
                    raised.set(vm.gpa, vm.str("location"), .{ .table = loc });
                }
            }
            if (raised.getName("stack") == .null) {
                if (e.trace) |tr| raised.set(vm.gpa, vm.str("stack"), vm.strValue(tr));
            }
            return e.value;
        }
        const t = vm.newTable(0, 3);
        t.set(vm.gpa, vm.str("message"), vm.strValue(e.message));
        if (e.loc) |l| {
            const loc = vm.newTable(0, 3);
            loc.set(vm.gpa, vm.str("line"), .{ .int = l.line });
            loc.set(vm.gpa, vm.str("column"), .{ .int = l.column });
            loc.set(vm.gpa, vm.str("origin"), vm.strValue(l.origin));
            t.set(vm.gpa, vm.str("location"), .{ .table = loc });
        }
        if (e.trace) |tr| t.set(vm.gpa, vm.str("stack"), vm.strValue(tr));
        return .{ .table = t };
    }

    // Allocation. Every object is linked into vm.objects; the collector runs
    // only at interpreter safe points (see gc.zig), never inside these.

    fn link(vm: *VM, o: *Object) void {
        o.next = vm.objects;
        vm.objects = o;
    }

    pub fn newTable(vm: *VM, narr: usize, nhash: usize) *Table {
        const t = vm.gpa.create(Table) catch oom();
        t.* = Table.init(vm.gpa, narr, nhash);
        vm.link(&t.obj);
        return t;
    }

    /// Creates (or finds, for short strings) a string with these bytes.
    pub fn newString(vm: *VM, bytes: []const u8) *String {
        if (bytes.len <= String.intern_limit) {
            const gop = vm.strings.getOrPutAdapted(vm.gpa, bytes, InternBytesCtx{}) catch oom();
            if (gop.found_existing) return gop.key_ptr.*;
            const s = vm.allocString(bytes);
            s.interned = true;
            s.hash_cache = String.hashBytes(bytes);
            gop.key_ptr.* = s;
            return s;
        }
        return vm.allocString(bytes);
    }

    fn allocString(vm: *VM, bytes: []const u8) *String {
        const mem = vm.gpa.alignedAlloc(u8, .of(String), String.allocSize(bytes.len)) catch oom();
        const s: *String = @ptrCast(@alignCast(mem.ptr));
        s.* = .{ .obj = .{ .kind = .string }, .len = bytes.len, .hash_cache = 0, .interned = false };
        @memcpy(s.mutableBytes(), bytes);
        mem[String.allocSize(bytes.len) - 1] = 0;
        vm.link(&s.obj);
        return s;
    }

    /// A string that is never interned (results of string building, which
    /// are rarely equal to an existing string).
    pub fn newStringRaw(vm: *VM, bytes: []const u8) *String {
        return vm.allocString(bytes);
    }

    /// Allocates an uninitialised string of the given length (never interned).
    pub fn newStringUninit(vm: *VM, len: usize) *String {
        const mem = vm.gpa.alignedAlloc(u8, .of(String), String.allocSize(len)) catch oom();
        const s: *String = @ptrCast(@alignCast(mem.ptr));
        s.* = .{ .obj = .{ .kind = .string }, .len = len, .hash_cache = 0, .interned = false };
        mem[String.allocSize(len) - 1] = 0;
        vm.link(&s.obj);
        return s;
    }

    pub fn str(vm: *VM, bytes: []const u8) Value {
        return .{ .string = vm.newString(bytes) };
    }

    pub fn strValue(vm: *VM, bytes: []const u8) Value {
        return .{ .string = vm.newString(bytes) };
    }

    pub fn newClosure(vm: *VM, proto: *Proto) *Closure {
        const c = vm.gpa.create(Closure) catch oom();
        const ups = vm.gpa.alloc(*Upvalue, proto.upvals.len) catch oom();
        c.* = .{ .obj = .{ .kind = .closure }, .proto = proto, .upvals = ups };
        vm.link(&c.obj);
        return c;
    }

    /// Wraps a native function as a function value. `nvals` are copied into
    /// the closure and reachable through `th.currentClosure().nvals`.
    pub fn newNative(vm: *VM, name: []const u8, f: object.NativeFn, nvals: []const Value) *Closure {
        const c = vm.gpa.create(Closure) catch oom();
        c.* = .{ .obj = .{ .kind = .closure }, .native = f, .name = vm.newString(name) };
        if (nvals.len > 0) c.nvals = vm.gpa.dupe(Value, nvals) catch oom();
        vm.link(&c.obj);
        return c;
    }

    pub fn nativeValue(vm: *VM, name: []const u8, f: object.NativeFn) Value {
        return .{ .function = vm.newNative(name, f, &.{}) };
    }

    pub fn newUpvalue(vm: *VM, v: Value) *Upvalue {
        const u = vm.gpa.create(Upvalue) catch oom();
        u.* = .{ .obj = .{ .kind = .upvalue }, .v = v };
        vm.link(&u.obj);
        return u;
    }

    pub fn newOpenUpvalue(vm: *VM, th: *Thread, idx: usize) *Upvalue {
        const u = vm.gpa.create(Upvalue) catch oom();
        u.* = .{ .obj = .{ .kind = .upvalue }, .th = th, .idx = idx };
        vm.link(&u.obj);
        return u;
    }

    /// Creates a userdata with a zeroed data block of `size` bytes.
    pub fn newUserdata(vm: *VM, size: usize, tname: []const u8, meta: ?*Table) *Userdata {
        const u = vm.gpa.create(Userdata) catch oom();
        const data = vm.gpa.alignedAlloc(u8, .@"16", size) catch oom();
        @memset(data, 0);
        u.* = .{ .obj = .{ .kind = .userdata }, .meta = meta, .tname = tname, .data = data };
        vm.link(&u.obj);
        return u;
    }

    /// Creates a userdata holding a value of type T.
    pub fn newUserdataOf(vm: *VM, comptime T: type, value: T, tname: []const u8, meta: ?*Table) *Userdata {
        const u = vm.newUserdata(@sizeOf(T), tname, meta);
        u.as(T).* = value;
        return u;
    }

    pub fn newProto(vm: *VM) *Proto {
        const p = vm.gpa.create(Proto) catch oom();
        p.* = .{ .obj = .{ .kind = .proto } };
        vm.link(&p.obj);
        return p;
    }

    pub fn newThread(vm: *VM, entry: ?*Closure) *Thread {
        vm.next_thread_id += 1;
        const th = vm.gpa.create(Thread) catch oom();
        th.* = Thread.init(vm, vm.next_thread_id, entry);
        vm.link(&th.obj);
        return th;
    }

    /// Looks up an environment variable.
    pub fn getenv(vm: *VM, name: []const u8) ?[]const u8 {
        if (vm.env) |env| return env.get(name);
        var buf: [256]u8 = undefined;
        if (name.len >= buf.len) return null;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const v = std.c.getenv(buf[0..name.len :0]) orelse return null;
        return std.mem.span(v);
    }

    // References (slang_ref): values kept alive in the registry under
    // integer keys.

    pub fn makeRef(vm: *VM, v: Value) i64 {
        if (v == .null) return 0;
        const id = vm.ref_free.pop() orelse blk: {
            const id = vm.next_ref;
            vm.next_ref += 1;
            break :blk id;
        };
        vm.registry.set(vm.gpa, .{ .int = id }, v);
        return id;
    }

    pub fn getRef(vm: *VM, id: i64) Value {
        if (id == 0) return .null;
        return vm.registry.get(.{ .int = id });
    }

    pub fn unref(vm: *VM, id: i64) void {
        if (id == 0) return;
        if (vm.registry.remove(vm.gpa, .{ .int = id }) == .null) return;
        vm.ref_free.append(vm.gpa, id) catch oom();
    }

    // Globals and loading.

    pub fn getGlobal(vm: *VM, name: []const u8) Value {
        return vm.globals.getName(name);
    }

    pub fn setGlobal(vm: *VM, name: []const u8, v: Value) void {
        vm.globals.set(vm.gpa, vm.str(name), v);
    }

    /// Installs a native function as a global.
    pub fn register(vm: *VM, name: []const u8, f: object.NativeFn) void {
        vm.setGlobal(name, vm.nativeValue(name, f));
    }

    /// Instantiates a top-level prototype; its _ENV upvalue is bound to the
    /// global table.
    pub fn load(vm: *VM, p: *Proto) *Closure {
        return vm.loadWithEnv(p, vm.globals);
    }

    /// Instantiates a top-level prototype whose globals are the table env
    /// (its _ENV upvalue): a sandbox sees only what env holds.
    pub fn loadWithEnv(vm: *VM, p: *Proto, env: *Table) *Closure {
        const cl = vm.newClosure(p);
        for (cl.upvals, 0..) |*u, i| {
            if (i == 0 and p.upvals[0].name.eqlBytes("_ENV")) {
                u.* = vm.newUpvalue(.{ .table = env });
            } else {
                u.* = vm.newUpvalue(.null);
            }
        }
        return cl;
    }

    /// Decodes a .slb container and instantiates it.
    pub fn loadBytes(vm: *VM, data: []const u8) Error!*Closure {
        const p = root.slb.decode(vm, data) catch |e| {
            return vm.raise("{s}", .{root.slb.errorMessage(e)});
        };
        return vm.load(p);
    }

    /// Loads "<name>.slb" from the embedded seed, or returns null.
    pub fn embeddedModule(vm: *VM, name: []const u8) Error!?*Closure {
        for (vm.embedded) |f| {
            if (std.mem.eql(u8, f.name, name)) return try vm.loadBytes(f.data);
        }
        return null;
    }

    /// Runs fn on the main thread.
    pub fn call(vm: *VM, f: Value, args: []const Value) Error!Value {
        return vm.main.call(f, args);
    }
};
