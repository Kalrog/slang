//! The debugger: a Debug Adapter Protocol server inside the VM. With
//! SLANG_DEBUG=PORT (or `slang run --debug PORT`) the VM listens on
//! 127.0.0.1:PORT before it runs anything, takes the editor's breakpoints and
//! starts the program at configurationDone.
//!
//! It runs on the interpreter's hooked loop (the one tracing and the
//! profiler use): before every instruction, check() sees whether a new line
//! starts and whether to stop there (a breakpoint, a step, a pause asked
//! for). Stopped, the VM blocks in check() serving the editor's questions
//! (stack, scopes, variables, evaluate) until it is told to go on. An error
//! that no try or pcall will catch stops it before the stack unwinds.
//!
//! Expressions (conditions, watches, the debug console) are compiled with
//! the paused frame's locals and upvalues as their globals (reading through
//! to the real globals) and run on a coroutine of their own, so the paused
//! one is left as it is.

const std = @import("std");
const root = @import("../vm.zig");
const oom = root.oom;
const VM = root.VM;
const Value = root.Value;
const Table = root.Table;
const Thread = root.Thread;
const Proto = root.Proto;
const Closure = root.Closure;
const Error = root.Error;
const Stringify = std.json.Stringify;

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

const Mode = enum { run, step_in, step_over, step_out, pause };

const Breakpoint = struct { line: u32, condition: ?[]u8 };

/// What a variablesReference stands for while stopped.
const Ref = union(enum) {
    locals: usize,
    upvalues: usize,
    globals,
    value: Value,
};

/// The code that runs an expression: compile(code, origin, env), called.
const eval_source =
    \\return func(code, env){
    \\  local f = compile(code, "debug console", env)
    \\  return f()
    \\}
;

/// The file a module was loaded from.
const path_source =
    \\return func(name){ return require("slang/compiler").module_path(name) }
;

pub const Debugger = struct {
    vm: *VM,
    gpa: std.mem.Allocator,
    fd: c_int,
    inbuf: std.ArrayList(u8) = .empty,
    seq: i64 = 1,
    breakpoints: std.StringHashMapUnmanaged(std.ArrayList(Breakpoint)) = .empty,
    stop_uncaught: bool = true,
    mode: Mode = .run,
    step_thread: ?*Thread = null,
    step_depth: usize = 0,
    // where the last instruction was: a line starts when this changes
    last_thread: ?*Thread = null,
    last_depth: usize = 0,
    last_proto: ?*Proto = null,
    last_line: u32 = 0,
    // the current proto's location entry covering [loc_from, loc_to)
    loc_from: usize = 0,
    loc_to: usize = 0,
    loc_line: u32 = 0,
    paused: ?*Thread = null,
    // the pc of the top frame while stopped at an instruction (the frame's
    // own pc is behind in the interpreter's loop); null at an error
    paused_pc: ?usize = null,
    refs: std.ArrayList(Ref) = .empty,
    // origin -> the file it is ("" when unknown)
    origins: std.StringHashMapUnmanaged([]u8) = .empty,
    // keeps what the debugger holds alive: helpers, values shown, coroutines
    roots: *Table,
    evaluating: bool = false,
    eval_error: []u8 = &.{},
    countdown: u32 = poll_every,
    reported_error: bool = false,
    configured: bool = false,
    terminated: bool = false,

    const poll_every = 4096;

    /// Listens on 127.0.0.1:port, waits for the editor and its configuration.
    pub fn start(vm: *VM, port: u16) !*Debugger {
        const listen_fd = socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (listen_fd < 0) return error.SocketFailed;
        defer _ = close(listen_fd);
        const one: c_int = 1;
        _ = std.c.setsockopt(listen_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &one, @sizeOf(c_int));
        var addr: std.c.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        if (std.c.bind(listen_fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
        if (std.c.listen(listen_fd, 1) != 0) return error.ListenFailed;
        var errbuf: [128]u8 = undefined;
        var ew = std.Io.File.stderr().writerStreaming(vm.io, &errbuf);
        ew.interface.print("slang: waiting for a debugger on 127.0.0.1:{d}\n", .{port}) catch {};
        ew.interface.flush() catch {};
        const fd = std.c.accept(listen_fd, null, null);
        if (fd < 0) return error.AcceptFailed;

        const d = vm.gpa.create(Debugger) catch oom();
        const roots = vm.newTable(0, 4);
        vm.registry.set(vm.gpa, vm.str("debugger"), .{ .table = roots });
        d.* = .{ .vm = vm, .gpa = vm.gpa, .fd = fd, .roots = roots };
        roots.set(vm.gpa, vm.str("eval"), try d.helper(eval_source));
        roots.set(vm.gpa, vm.str("path"), try d.helper(path_source));
        // the configuration: breakpoints, then configurationDone
        while (!d.configured and !d.terminated) {
            const msg = d.receive(true) orelse break;
            defer msg.deinit();
            d.dispatch(msg.value);
        }
        return d;
    }

    fn helper(d: *Debugger, source: []const u8) !Value {
        const f = try d.vm.call(d.vm.getGlobal("compile"), &.{ d.vm.str(source), d.vm.str("debugger") });
        return try d.vm.call(f, &.{});
    }

    // ------------------------------------------------------------ the protocol

    /// The next message, or null when the editor went away (or, not
    /// blocking, when none has arrived).
    fn receive(d: *Debugger, block: bool) ?std.json.Parsed(std.json.Value) {
        while (true) {
            if (d.takeMessage()) |m| return m;
            if (!block) {
                var fds = [_]std.c.pollfd{.{ .fd = d.fd, .events = std.c.POLL.IN, .revents = 0 }};
                if (std.c.poll(&fds, 1, 0) <= 0) return null;
            }
            var buf: [4096]u8 = undefined;
            const n = std.c.read(d.fd, &buf, buf.len);
            if (n <= 0) {
                d.terminated = true;
                return null;
            }
            d.inbuf.appendSlice(d.gpa, buf[0..@intCast(n)]) catch oom();
        }
    }

    fn takeMessage(d: *Debugger) ?std.json.Parsed(std.json.Value) {
        const data = d.inbuf.items;
        const head_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        var length: ?usize = null;
        var lines = std.mem.splitSequence(u8, data[0..head_end], "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), "content-length")) {
                length = std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch null;
            }
        }
        const len = length orelse return null;
        const body = head_end + 4;
        if (data.len < body + len) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, d.gpa, data[body .. body + len], .{}) catch null;
        const rest = data.len - (body + len);
        std.mem.copyForwards(u8, d.inbuf.items[0..rest], data[body + len ..]);
        d.inbuf.shrinkRetainingCapacity(rest);
        return parsed orelse d.takeMessage();
    }

    fn sendBody(d: *Debugger, body: []const u8) void {
        var head: [64]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
        d.writeAll(h);
        d.writeAll(body);
    }

    fn writeAll(d: *Debugger, bytes: []const u8) void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(d.fd, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) {
                d.terminated = true;
                return;
            }
            off += @intCast(n);
        }
    }

    /// A message being written: begin, fields through js, then send.
    const Out = struct {
        aw: std.Io.Writer.Allocating,
        js: Stringify,

        fn send(o: *Out, d: *Debugger) void {
            o.js.endObject() catch {};
            d.sendBody(o.aw.writer.buffered());
            o.aw.deinit();
        }
    };

    fn begin(d: *Debugger, kind: []const u8) *Out {
        const o = d.gpa.create(Out) catch oom();
        o.aw = .init(d.gpa);
        o.js = .{ .writer = &o.aw.writer, .options = .{} };
        o.js.beginObject() catch {};
        o.js.objectField("seq") catch {};
        o.js.write(d.seq) catch {};
        d.seq += 1;
        o.js.objectField("type") catch {};
        o.js.write(kind) catch {};
        return o;
    }

    fn finishOut(d: *Debugger, o: *Out) void {
        o.send(d);
        d.gpa.destroy(o);
    }

    /// A response: its body is written by the caller between this and
    /// finishResponse (the "body" field is open when body is true).
    fn response(d: *Debugger, req: std.json.Value, success: bool, message: ?[]const u8, body: bool) *Out {
        const o = d.begin("response");
        o.js.objectField("request_seq") catch {};
        o.js.write(field(req, "seq") orelse std.json.Value{ .integer = 0 }) catch {};
        o.js.objectField("command") catch {};
        o.js.write(str(req, "command") orelse "") catch {};
        o.js.objectField("success") catch {};
        o.js.write(success) catch {};
        if (message) |m| {
            o.js.objectField("message") catch {};
            o.js.write(m) catch {};
        }
        if (body) {
            o.js.objectField("body") catch {};
            o.js.beginObject() catch {};
        }
        return o;
    }

    fn finishResponse(d: *Debugger, o: *Out, body: bool) void {
        if (body) o.js.endObject() catch {};
        d.finishOut(o);
    }

    fn ack(d: *Debugger, req: std.json.Value) void {
        d.finishResponse(d.response(req, true, null, false), false);
    }

    fn fail(d: *Debugger, req: std.json.Value, message: []const u8) void {
        d.finishResponse(d.response(req, false, message, false), false);
    }

    fn event(d: *Debugger, name: []const u8) *Out {
        const o = d.begin("event");
        o.js.objectField("event") catch {};
        o.js.write(name) catch {};
        o.js.objectField("body") catch {};
        o.js.beginObject() catch {};
        return o;
    }

    fn finishEvent(d: *Debugger, o: *Out) void {
        o.js.endObject() catch {};
        d.finishOut(o);
    }

    fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
        return switch (v) {
            .object => |o| o.get(name),
            else => null,
        };
    }

    fn str(v: std.json.Value, name: []const u8) ?[]const u8 {
        const f = field(v, name) orelse return null;
        return switch (f) {
            .string => |s| s,
            else => null,
        };
    }

    fn int(v: std.json.Value, name: []const u8) ?i64 {
        const f = field(v, name) orelse return null;
        return switch (f) {
            .integer => |i| i,
            else => null,
        };
    }

    // ------------------------------------------------------------ requests

    fn dispatch(d: *Debugger, msg: std.json.Value) void {
        if (!std.mem.eql(u8, str(msg, "type") orelse "", "request")) return;
        const cmd = str(msg, "command") orelse return;
        const args = field(msg, "arguments") orelse std.json.Value{ .null = {} };
        if (std.mem.eql(u8, cmd, "initialize")) {
            const o = d.response(msg, true, null, true);
            o.js.objectField("supportsConfigurationDoneRequest") catch {};
            o.js.write(true) catch {};
            o.js.objectField("supportsConditionalBreakpoints") catch {};
            o.js.write(true) catch {};
            o.js.objectField("supportsEvaluateForHovers") catch {};
            o.js.write(true) catch {};
            o.js.objectField("supportsTerminateRequest") catch {};
            o.js.write(true) catch {};
            o.js.objectField("exceptionBreakpointFilters") catch {};
            o.js.beginArray() catch {};
            o.js.beginObject() catch {};
            o.js.objectField("filter") catch {};
            o.js.write("uncaught") catch {};
            o.js.objectField("label") catch {};
            o.js.write("Uncaught errors") catch {};
            o.js.objectField("default") catch {};
            o.js.write(true) catch {};
            o.js.endObject() catch {};
            o.js.endArray() catch {};
            d.finishResponse(o, true);
            d.finishEvent(d.event("initialized"));
        } else if (std.mem.eql(u8, cmd, "launch") or std.mem.eql(u8, cmd, "attach")) {
            // stopOnEntry: stop at the first line
            if (field(args, "stopOnEntry")) |s| if (s == .bool and s.bool) {
                d.mode = .step_in;
            };
            d.ack(msg);
        } else if (std.mem.eql(u8, cmd, "setBreakpoints")) {
            d.setBreakpoints(msg, args);
        } else if (std.mem.eql(u8, cmd, "setExceptionBreakpoints")) {
            d.stop_uncaught = false;
            if (field(args, "filters")) |filters| if (filters == .array) {
                for (filters.array.items) |f| {
                    if (f == .string and std.mem.eql(u8, f.string, "uncaught")) d.stop_uncaught = true;
                }
            };
            d.ack(msg);
        } else if (std.mem.eql(u8, cmd, "configurationDone")) {
            d.ack(msg);
            d.configured = true;
        } else if (std.mem.eql(u8, cmd, "threads")) {
            const o = d.response(msg, true, null, true);
            o.js.objectField("threads") catch {};
            o.js.beginArray() catch {};
            o.js.beginObject() catch {};
            o.js.objectField("id") catch {};
            o.js.write(1) catch {};
            o.js.objectField("name") catch {};
            o.js.write("main") catch {};
            o.js.endObject() catch {};
            o.js.endArray() catch {};
            d.finishResponse(o, true);
        } else if (std.mem.eql(u8, cmd, "stackTrace")) {
            d.stackTrace(msg);
        } else if (std.mem.eql(u8, cmd, "scopes")) {
            d.scopes(msg, args);
        } else if (std.mem.eql(u8, cmd, "variables")) {
            d.variables(msg, args);
        } else if (std.mem.eql(u8, cmd, "evaluate")) {
            d.evaluateRequest(msg, args);
        } else if (std.mem.eql(u8, cmd, "continue")) {
            const o = d.response(msg, true, null, true);
            o.js.objectField("allThreadsContinued") catch {};
            o.js.write(true) catch {};
            d.finishResponse(o, true);
            d.resumeWith(.run);
        } else if (std.mem.eql(u8, cmd, "next")) {
            d.ack(msg);
            d.resumeWith(.step_over);
        } else if (std.mem.eql(u8, cmd, "stepIn")) {
            d.ack(msg);
            d.resumeWith(.step_in);
        } else if (std.mem.eql(u8, cmd, "stepOut")) {
            d.ack(msg);
            d.resumeWith(.step_out);
        } else if (std.mem.eql(u8, cmd, "pause")) {
            d.ack(msg);
            if (d.paused == null) d.mode = .pause;
        } else if (std.mem.eql(u8, cmd, "disconnect") or std.mem.eql(u8, cmd, "terminate")) {
            d.ack(msg);
            d.vm.flush();
            std.process.exit(0);
        } else {
            d.fail(msg, "not supported");
        }
    }

    fn resumeWith(d: *Debugger, mode: Mode) void {
        const th = d.paused orelse return;
        d.mode = mode;
        d.step_thread = th;
        d.step_depth = th.frames.items.len;
        d.paused = null;
    }

    fn setBreakpoints(d: *Debugger, msg: std.json.Value, args: std.json.Value) void {
        const source = field(args, "source") orelse std.json.Value{ .null = {} };
        const path = str(source, "path") orelse return d.fail(msg, "a source path is needed");
        var list: std.ArrayList(Breakpoint) = .empty;
        if (field(args, "breakpoints")) |bps| if (bps == .array) {
            for (bps.array.items) |bp| {
                const line = int(bp, "line") orelse continue;
                const cond = str(bp, "condition");
                list.append(d.gpa, .{
                    .line = @intCast(@max(0, line)),
                    .condition = if (cond != null and cond.?.len > 0) d.gpa.dupe(u8, cond.?) catch oom() else null,
                }) catch oom();
            }
        };
        const gop = d.breakpoints.getOrPut(d.gpa, path) catch oom();
        if (gop.found_existing) {
            for (gop.value_ptr.items) |bp| if (bp.condition) |c| d.gpa.free(c);
            gop.value_ptr.deinit(d.gpa);
        } else {
            gop.key_ptr.* = d.gpa.dupe(u8, path) catch oom();
        }
        gop.value_ptr.* = list;
        const o = d.response(msg, true, null, true);
        o.js.objectField("breakpoints") catch {};
        o.js.beginArray() catch {};
        for (list.items) |bp| {
            o.js.beginObject() catch {};
            o.js.objectField("verified") catch {};
            o.js.write(true) catch {};
            o.js.objectField("line") catch {};
            o.js.write(bp.line) catch {};
            o.js.endObject() catch {};
        }
        o.js.endArray() catch {};
        d.finishResponse(o, true);
    }

    // ------------------------------------------------------------ where the program is

    /// The source line of pc in p, remembering the location entry around it.
    fn lineOf(d: *Debugger, p: *Proto, pc: usize) u32 {
        if (p == d.last_proto and pc >= d.loc_from and pc < d.loc_to) return d.loc_line;
        var line: u32 = 0;
        var from: usize = 0;
        var to: usize = p.code.len + 1;
        for (p.locs, 0..) |l, i| {
            if (l.first_pc <= pc) {
                line = l.line;
                from = l.first_pc;
                to = if (i + 1 < p.locs.len) p.locs[i + 1].first_pc else p.code.len + 1;
            } else break;
        }
        d.loc_from = from;
        d.loc_to = to;
        d.loc_line = line;
        return line;
    }

    /// The file an origin is: a path (made absolute), or the file require
    /// loaded the module from; "" when it cannot be told.
    fn pathOf(d: *Debugger, origin: []const u8) []const u8 {
        if (d.origins.get(origin)) |p| return p;
        var result: []u8 = d.gpa.dupe(u8, "") catch oom();
        if (std.mem.endsWith(u8, origin, ".slang")) {
            if (std.fs.path.isAbsolute(origin)) {
                d.gpa.free(result);
                result = d.gpa.dupe(u8, origin) catch oom();
            } else if (std.process.currentPathAlloc(d.vm.io, d.gpa)) |cwd| {
                defer d.gpa.free(cwd);
                d.gpa.free(result);
                result = std.fs.path.resolveAlloc(d.gpa, &.{ cwd, origin }) catch oom();
            } else |_| {}
        } else {
            const v = d.isolated(d.roots.getName("path"), &.{d.vm.str(origin)}) catch Value.null;
            if (v.asBytes()) |b| {
                d.gpa.free(result);
                result = d.gpa.dupe(u8, b) catch oom();
            }
        }
        d.origins.put(d.gpa, d.gpa.dupe(u8, origin) catch oom(), result) catch oom();
        return result;
    }

    /// Called before every instruction of the hooked loop.
    pub fn check(d: *Debugger, th: *Thread, fi: usize, pc: usize) void {
        if (d.evaluating or d.terminated) return;
        d.reported_error = false;
        d.countdown -%= 1;
        if (d.countdown == 0) {
            d.countdown = poll_every;
            // what the editor sent meanwhile (a pause, new breakpoints)
            while (d.receive(false)) |msg| {
                defer msg.deinit();
                d.dispatch(msg.value);
            }
        }
        const frame = th.frames.items[fi];
        const p = frame.cl.proto orelse return;
        const depth = th.frames.items.len;
        const same_place = th == d.last_thread and depth == d.last_depth and p == d.last_proto;
        if (same_place and pc >= d.loc_from and pc < d.loc_to) return;
        const line = d.lineOf(p, pc);
        if (same_place and line == d.last_line) return;
        d.last_thread = th;
        d.last_depth = depth;
        d.last_proto = p;
        d.last_line = line;
        if (line == 0) return;
        d.paused_pc = pc;
        switch (d.mode) {
            .pause => return d.stop(th, "pause", null),
            .step_in => return d.stop(th, "step", null),
            .step_over => if (th != d.step_thread or depth <= d.step_depth) return d.stop(th, "step", null),
            .step_out => if (th != d.step_thread or depth < d.step_depth) return d.stop(th, "step", null),
            .run => {},
        }
        if (d.breakpoints.count() == 0) return;
        const path = d.pathOf(p.origin());
        const list = d.breakpoints.get(path) orelse return;
        for (list.items) |bp| {
            if (bp.line != line) continue;
            if (bp.condition) |c| {
                const v = d.evaluate(th, fi, c) catch continue;
                if (!v.truthy()) continue;
            }
            return d.stop(th, "breakpoint", null);
        }
    }

    /// An error is being raised: stop when no try or pcall will catch it.
    pub fn raised(d: *Debugger, th: *Thread) void {
        if (d.evaluating or d.terminated or !d.stop_uncaught or d.reported_error) return;
        if (caught(th)) return;
        if (!th.is_main and caught(d.vm.main)) return;
        d.reported_error = true;
        d.paused_pc = null;
        const message: []const u8 = if (d.vm.err) |e| e.message else "error";
        d.stop(th, "exception", message);
    }

    fn caught(th: *Thread) bool {
        if (th.handlers.items.len > 0) return true;
        for (th.frames.items) |fr| if (fr.protected) return true;
        return false;
    }

    fn stop(d: *Debugger, th: *Thread, reason: []const u8, text: ?[]const u8) void {
        d.paused = th;
        d.mode = .run;
        const o = d.event("stopped");
        o.js.objectField("reason") catch {};
        o.js.write(reason) catch {};
        o.js.objectField("threadId") catch {};
        o.js.write(1) catch {};
        o.js.objectField("allThreadsStopped") catch {};
        o.js.write(true) catch {};
        if (text) |t| {
            o.js.objectField("text") catch {};
            o.js.write(t) catch {};
            o.js.objectField("description") catch {};
            o.js.write(t) catch {};
        }
        d.finishEvent(o);
        d.vm.flush();
        while (d.paused != null and !d.terminated) {
            const msg = d.receive(true) orelse break;
            defer msg.deinit();
            d.dispatch(msg.value);
        }
        // what the editor was shown is no longer asked for (the rest of
        // the line stopped at is not a new line)
        d.refs.clearRetainingCapacity();
        d.roots.set(d.gpa, d.vm.str("shown"), .null);
    }

    // ------------------------------------------------------------ stack, scopes, variables

    /// The pc a frame is at: the instruction about to run for the top one,
    /// the call for the others.
    fn framePc(d: *Debugger, th: *Thread, fi: usize) usize {
        const pc = th.frames.items[fi].pc;
        if (fi + 1 == th.frames.items.len) return d.paused_pc orelse (if (pc > 0) pc - 1 else 0);
        return if (pc > 0) pc - 1 else 0;
    }

    fn stackTrace(d: *Debugger, msg: std.json.Value) void {
        const th = d.paused orelse return d.fail(msg, "not stopped");
        const o = d.response(msg, true, null, true);
        o.js.objectField("stackFrames") catch {};
        o.js.beginArray() catch {};
        var count: usize = 0;
        var i = th.frames.items.len;
        while (i > 0) {
            i -= 1;
            const fr = th.frames.items[i];
            o.js.beginObject() catch {};
            o.js.objectField("id") catch {};
            o.js.write(i + 1) catch {};
            o.js.objectField("name") catch {};
            if (fr.cl.proto) |p| {
                o.js.write(if (p.name) |n| n.bytes() else if (i == 0) "main" else "(anonymous function)") catch {};
                const pc = d.framePc(th, i);
                const loc = p.location(pc);
                const path = d.pathOf(p.origin());
                if (path.len > 0) {
                    o.js.objectField("source") catch {};
                    o.js.beginObject() catch {};
                    o.js.objectField("name") catch {};
                    o.js.write(std.fs.path.basename(path)) catch {};
                    o.js.objectField("path") catch {};
                    o.js.write(path) catch {};
                    o.js.endObject() catch {};
                }
                o.js.objectField("line") catch {};
                o.js.write(if (loc) |l| l.line else 0) catch {};
                o.js.objectField("column") catch {};
                o.js.write(if (loc) |l| l.column else 0) catch {};
            } else {
                var nb: [96]u8 = undefined;
                o.js.write(std.fmt.bufPrint(&nb, "[native {s}]", .{fr.cl.nameBytes()}) catch "[native]") catch {};
                o.js.objectField("line") catch {};
                o.js.write(0) catch {};
                o.js.objectField("column") catch {};
                o.js.write(0) catch {};
                o.js.objectField("presentationHint") catch {};
                o.js.write("subtle") catch {};
            }
            o.js.endObject() catch {};
            count += 1;
        }
        o.js.endArray() catch {};
        o.js.objectField("totalFrames") catch {};
        o.js.write(count) catch {};
        d.finishResponse(o, true);
    }

    fn newRef(d: *Debugger, r: Ref) usize {
        d.refs.append(d.gpa, r) catch oom();
        if (r == .value) {
            // shown values stay alive while stopped
            var shown = d.roots.getName("shown").asTable();
            if (shown == null) {
                shown = d.vm.newTable(0, 0);
                d.roots.set(d.gpa, d.vm.str("shown"), .{ .table = shown.? });
            }
            shown.?.append(d.gpa, r.value);
        }
        return d.refs.items.len;
    }

    fn scopes(d: *Debugger, msg: std.json.Value, args: std.json.Value) void {
        const th = d.paused orelse return d.fail(msg, "not stopped");
        const id = int(args, "frameId") orelse 0;
        if (id < 1 or id > th.frames.items.len) return d.fail(msg, "no such frame");
        const fi: usize = @intCast(id - 1);
        const o = d.response(msg, true, null, true);
        o.js.objectField("scopes") catch {};
        o.js.beginArray() catch {};
        const entries = [_]struct { name: []const u8, ref: Ref, expensive: bool }{
            .{ .name = "Locals", .ref = .{ .locals = fi }, .expensive = false },
            .{ .name = "Upvalues", .ref = .{ .upvalues = fi }, .expensive = false },
            .{ .name = "Globals", .ref = .globals, .expensive = true },
        };
        for (entries) |e| {
            o.js.beginObject() catch {};
            o.js.objectField("name") catch {};
            o.js.write(e.name) catch {};
            o.js.objectField("variablesReference") catch {};
            o.js.write(d.newRef(e.ref)) catch {};
            o.js.objectField("expensive") catch {};
            o.js.write(e.expensive) catch {};
            o.js.endObject() catch {};
        }
        o.js.endArray() catch {};
        d.finishResponse(o, true);
    }

    /// Whether a local's name is one the program wrote (codegen's hidden
    /// locals are not).
    fn shownName(name: []const u8) bool {
        if (name.len == 0 or std.mem.startsWith(u8, name, "__")) return false;
        for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
        }
        return true;
    }

    const Named = struct { name: []const u8, value: Value };

    /// The locals of frame fi in scope at its pc, innermost last.
    fn frameLocals(d: *Debugger, th: *Thread, fi: usize, out: *std.ArrayList(Named)) void {
        const fr = th.frames.items[fi];
        const p = fr.cl.proto orelse return;
        const pc = d.framePc(th, fi);
        for (p.locals) |l| {
            if (l.start_pc <= pc and pc < l.end_pc and shownName(l.name.bytes())) {
                const slot = fr.base + l.reg;
                const v: Value = if (slot < th.top or slot < th.stack.len) th.stack[slot] else .null;
                // a later local of the same name shadows the earlier one
                var replaced = false;
                for (out.items) |*e| {
                    if (std.mem.eql(u8, e.name, l.name.bytes())) {
                        e.value = v;
                        replaced = true;
                    }
                }
                if (!replaced) out.append(d.gpa, .{ .name = l.name.bytes(), .value = v }) catch oom();
            }
        }
    }

    fn frameUpvalues(d: *Debugger, th: *Thread, fi: usize, out: *std.ArrayList(Named)) void {
        const cl = th.frames.items[fi].cl;
        const p = cl.proto orelse return;
        for (p.upvals, 0..) |u, i| {
            if (i < cl.upvals.len and shownName(u.name.bytes())) {
                out.append(d.gpa, .{ .name = u.name.bytes(), .value = cl.getUpvalue(i) }) catch oom();
            }
        }
    }

    fn variables(d: *Debugger, msg: std.json.Value, args: std.json.Value) void {
        const th = d.paused orelse return d.fail(msg, "not stopped");
        const id = int(args, "variablesReference") orelse 0;
        if (id < 1 or id > d.refs.items.len) return d.fail(msg, "no such variables");
        const r = d.refs.items[@intCast(id - 1)];
        var list: std.ArrayList(Named) = .empty;
        defer list.deinit(d.gpa);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| d.gpa.free(n);
            names.deinit(d.gpa);
        }
        switch (r) {
            .locals => |fi| if (fi < th.frames.items.len) d.frameLocals(th, fi, &list),
            .upvalues => |fi| if (fi < th.frames.items.len) d.frameUpvalues(th, fi, &list),
            .globals => d.tableEntries(d.vm.globals, &list, &names),
            .value => |v| if (v.asTable()) |t| {
                d.tableEntries(t, &list, &names);
                if (t.meta) |m| list.append(d.gpa, .{ .name = "@meta", .value = .{ .table = m } }) catch oom();
            },
        }
        const o = d.response(msg, true, null, true);
        o.js.objectField("variables") catch {};
        o.js.beginArray() catch {};
        for (list.items) |e| {
            o.js.beginObject() catch {};
            o.js.objectField("name") catch {};
            o.js.write(e.name) catch {};
            d.writeValueFields(o, e.value);
            o.js.endObject() catch {};
        }
        o.js.endArray() catch {};
        d.finishResponse(o, true);
    }

    /// A table's entries as names and values: string keys as they are, the
    /// others rendered in brackets.
    fn tableEntries(d: *Debugger, t: *Table, out: *std.ArrayList(Named), names: *std.ArrayList([]u8)) void {
        var it = t.iterator();
        var shown: usize = 0;
        while (it.next()) |e| : (shown += 1) {
            if (shown >= 500) break;
            const name: []const u8 = if (e.key.asBytes()) |b| b else blk: {
                const r = root.format.valueToOwned(d.gpa, e.key);
                defer d.gpa.free(r);
                const n = std.fmt.allocPrint(d.gpa, "[{s}]", .{r}) catch oom();
                names.append(d.gpa, n) catch oom();
                break :blk n;
            };
            out.append(d.gpa, .{ .name = name, .value = e.val }) catch oom();
        }
    }

    /// value, type and variablesReference (a table opens) of a value.
    fn writeValueFields(d: *Debugger, o: *Out, v: Value) void {
        const text = render(d.gpa, v);
        defer d.gpa.free(text);
        o.js.objectField("value") catch {};
        o.js.write(text) catch {};
        o.js.objectField("type") catch {};
        o.js.write(v.typeName()) catch {};
        o.js.objectField("variablesReference") catch {};
        o.js.write(if (v.asTable() != null) d.newRef(.{ .value = v }) else 0) catch {};
    }

    fn render(gpa: std.mem.Allocator, v: Value) []u8 {
        if (v.asBytes()) |b| {
            const shown = if (b.len > 200) b[0..200] else b;
            return std.fmt.allocPrint(gpa, "\"{s}\"{s}", .{ shown, if (b.len > 200) "..." else "" }) catch oom();
        }
        const full = root.format.valueToOwned(gpa, v);
        if (full.len <= 200) return full;
        defer gpa.free(full);
        return std.fmt.allocPrint(gpa, "{s}...", .{full[0..200]}) catch oom();
    }

    // ------------------------------------------------------------ evaluation

    /// Runs f(args) on a coroutine of its own. The VM's pending error (the
    /// one stopped at) is put back after; an error of f's is in
    /// eval_error, and error.Slang is returned.
    fn isolated(d: *Debugger, f: Value, args: []const Value) Error!Value {
        const vm = d.vm;
        const cl = f.asClosure() orelse return error.Slang;
        const co = vm.newThread(cl);
        d.roots.set(d.gpa, vm.str("running"), .{ .thread = co });
        defer d.roots.set(d.gpa, vm.str("running"), .null);
        const saved = vm.err;
        vm.err = null;
        defer vm.err = saved;
        const was = d.evaluating;
        d.evaluating = true;
        defer d.evaluating = was;
        if (co.resumeCo(args)) |v| {
            return v;
        } else |_| {
            var e = vm.takeError();
            defer e.deinit(d.gpa);
            d.gpa.free(d.eval_error);
            d.eval_error = d.gpa.dupe(u8, e.message) catch oom();
            return error.Slang;
        }
    }

    /// An expression evaluated in frame fi: its locals and upvalues are its
    /// globals, which read through to the real ones. Statements are run
    /// when it is not an expression.
    fn evaluate(d: *Debugger, th: *Thread, fi: usize, expression: []const u8) Error!Value {
        const vm = d.vm;
        const env = vm.newTable(0, 8);
        d.roots.set(d.gpa, vm.str("env"), .{ .table = env });
        defer d.roots.set(d.gpa, vm.str("env"), .null);
        var list: std.ArrayList(Named) = .empty;
        defer list.deinit(d.gpa);
        d.frameUpvalues(th, fi, &list);
        d.frameLocals(th, fi, &list);
        for (list.items) |e| env.set(d.gpa, vm.str(e.name), e.value);
        const meta = vm.newTable(0, 1);
        meta.set(d.gpa, vm.str("__index"), .{ .table = vm.globals });
        env.meta = meta;
        const code = std.fmt.allocPrint(d.gpa, "return {s}", .{expression}) catch oom();
        defer d.gpa.free(code);
        const eval = d.roots.getName("eval");
        return d.isolated(eval, &.{ vm.str(code), .{ .table = env } }) catch
            d.isolated(eval, &.{ vm.str(expression), .{ .table = env } });
    }

    fn evaluateRequest(d: *Debugger, msg: std.json.Value, args: std.json.Value) void {
        const th = d.paused orelse return d.fail(msg, "not stopped");
        const expression = str(args, "expression") orelse return d.fail(msg, "no expression");
        var fi: usize = th.frames.items.len - 1;
        if (int(args, "frameId")) |id| {
            if (id >= 1 and id <= th.frames.items.len) fi = @intCast(id - 1);
        }
        const v = d.evaluate(th, fi, expression) catch return d.fail(msg, d.eval_error);
        const o = d.response(msg, true, null, true);
        const text = render(d.gpa, v);
        defer d.gpa.free(text);
        o.js.objectField("result") catch {};
        o.js.write(text) catch {};
        o.js.objectField("type") catch {};
        o.js.write(v.typeName()) catch {};
        o.js.objectField("variablesReference") catch {};
        o.js.write(if (v.asTable() != null) d.newRef(.{ .value = v }) else 0) catch {};
        d.finishResponse(o, true);
    }

    // ------------------------------------------------------------ the end

    /// The program ended with code: the editor is told.
    pub fn finish(d: *Debugger, code: u8) void {
        if (d.terminated) return;
        const o = d.event("exited");
        o.js.objectField("exitCode") catch {};
        o.js.write(code) catch {};
        d.finishEvent(o);
        d.finishEvent(d.event("terminated"));
        d.terminated = true;
        _ = close(d.fd);
    }
};
