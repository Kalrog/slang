//! The slang command line: run, test, repl, compile, disasm. An executable
//! built by `slang build` runs its bundled program instead.

const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Closure = vm_mod.Closure;
const Proto = vm_mod.Proto;
const Error = vm_mod.Error;
const stdlib = @import("stdlib/stdlib.zig");
const oslib = @import("stdlib/oslib.zig");
const boot = @import("boot.zig");
const bundle = @import("bundle/exe.zig");
const bundle_format = @import("bundle/format.zig");
const isolates = @import("stdlib/isolatelib.zig");

// The C API must be compiled and exported even though nothing in the CLI
// calls it: native extensions resolve the slang_* symbols against the
// executable.
comptime {
    _ = @import("capi.zig");
}

test {
    _ = @import("bundle/exe.zig");
    _ = @import("bundle/format.zig");
    _ = @import("bundle/macho.zig");
}

var stderr_buf: [4096]u8 = undefined;

fn stderr(io: std.Io) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(io, &stderr_buf);
}

fn usage(io: std.Io) noreturn {
    var w = stderr(io);
    w.interface.writeAll(
        \\usage:
        \\  slang run [--explain] [--profile out.folded] [--debug port] <file.slang|file.slb> [args...]
        \\  slang test [--json] [--only "group / test"] [dir|file]
        \\                              run every *test.slang file in dir (default ./test), or one file
        \\  slang repl
        \\  slang compile <file.slang> [-o out.slb] [--origin name] [--strip]
        \\  slang disasm <file.slb|file.slang>
        \\  slang highlight [--check] <file>
        \\                              print the tokens and parse errors of a file as JSON
        \\                              (--check: also compile errors and lint warnings)
        \\  slang expand <file>          print a file as slang source after its extensions were applied
        \\  slang fmt [--check] [--stdout] <file|dir>...
        \\                              format files in place (--check: list the ones that would change)
        \\  slang get                   fetch the project's packages and write slang.lock
        \\  slang update [package...]   move packages to their newest version (same major)
        \\  slang deps                  list the packages the project uses and who asks for them
        \\  slang doc [-o dir] [file|dir...]
        \\                              HTML documentation of the modules (default: the project, or slang's library)
        \\  slang build [--dir] [-o out] [--list] [--strip] [file.slang]
        \\                              one executable of a program, its modules and its assets
        \\
    ) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const built = bundle.open(init.gpa, io) catch |e| {
        var w = stderr(io);
        w.interface.print("this executable's bundle is damaged: {t}\n", .{e}) catch {};
        w.interface.flush() catch {};
        return 1;
    };
    if (built) |b| return runBundled(init, b);

    // (WASI needs the allocator; elsewhere it is not used)
    var it = init.minimal.args.iterateAllocator(init.gpa) catch oom();
    defer it.deinit();
    _ = it.next();
    const cmd = it.next() orelse usage(io);

    // the remaining arguments
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(init.gpa);
    while (it.next()) |a| rest.append(init.gpa, a) catch oom();
    const args = rest.items;

    if (std.mem.eql(u8, cmd, "run")) {
        var run_args = args;
        var explain = false;
        var profile: ?[]const u8 = null;
        while (run_args.len > 0) {
            if (std.mem.eql(u8, run_args[0], "--explain")) {
                explain = true;
                run_args = run_args[1..];
            } else if (std.mem.eql(u8, run_args[0], "--profile") and run_args.len > 1) {
                profile = run_args[1];
                run_args = run_args[2..];
            } else if (std.mem.eql(u8, run_args[0], "--debug") and run_args.len > 1) {
                debug_port = run_args[1];
                run_args = run_args[2..];
            } else break;
        }
        if (run_args.len < 1) usage(io);
        run(init, run_args[0], run_args[1..], explain, profile);
    } else if (std.mem.eql(u8, cmd, "test")) {
        return runTests(init, args);
    } else if (std.mem.eql(u8, cmd, "repl")) {
        repl(init);
    } else if (std.mem.eql(u8, cmd, "compile")) {
        if (args.len < 1) usage(io);
        compileFile(init, args);
    } else if (std.mem.eql(u8, cmd, "highlight")) {
        if (args.len < 1) usage(io);
        const check = std.mem.eql(u8, args[0], "--check");
        if (check and args.len < 2) usage(io);
        highlightFile(init, if (check) args[1] else args[0], check);
    } else if (std.mem.eql(u8, cmd, "expand")) {
        if (args.len < 1) usage(io);
        expandFile(init, args[0]);
    } else if (std.mem.eql(u8, cmd, "fmt")) {
        return toolMain(init, "slang/format", args);
    } else if (std.mem.eql(u8, cmd, "doc")) {
        return toolMain(init, "slang/doc", args);
    } else if (std.mem.eql(u8, cmd, "build")) {
        return toolMain(init, "slang/build", args);
    } else if (std.mem.eql(u8, cmd, "get") or std.mem.eql(u8, cmd, "update") or std.mem.eql(u8, cmd, "deps")) {
        // slang/pkg's main takes the command first
        var all: std.ArrayList([]const u8) = .empty;
        defer all.deinit(init.gpa);
        all.append(init.gpa, cmd) catch oom();
        all.appendSlice(init.gpa, args) catch oom();
        return toolMain(init, "slang/pkg", all.items);
    } else if (std.mem.eql(u8, cmd, "disasm")) {
        if (args.len < 1) usage(io);
        disasmFile(init, args[0]);
    } else {
        usage(io);
    }
    return 0;
}

fn stripSuffix(s: []const u8, suffix: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, s, suffix)) s[0 .. s.len - suffix.len] else s;
}

fn newVM(init: std.process.Init, args: []const []const u8) *VM {
    const vm = VM.create(init.gpa, init.io, init.environ_map);
    vm.args = args;
    vm.embedded = &boot.embedded_files;
    stdlib.open(vm);
    stdlib.boot(vm) catch fail(vm);
    vm.trace = init.environ_map.get("SLANG_TRACE") != null;
    // SLANG_PROFILE=out.folded profiles any command (see vm/profile.zig)
    if (init.environ_map.get("SLANG_PROFILE")) |path| {
        vm.profiler = vm_mod.Profiler.create(vm.backing, vm.io, path);
    }
    // SLANG_DEBUG=port (or run --debug port): an editor debugs the program
    const port_text = debug_port orelse init.environ_map.get("SLANG_DEBUG");
    if (comptime @import("builtin").cpu.arch.isWasm()) {
        // no sockets in a browser
    } else if (port_text) |text| {
        const port = std.fmt.parseInt(u16, text, 10) catch failMsg(vm, "the debug port must be a number, not {s}", .{text});
        vm.debugger = vm_mod.Debugger.start(vm, port) catch |e| failMsg(vm, "cannot debug on port {d}: {t}", .{ port, e });
    }
    return vm;
}

/// `slang run --debug port`
var debug_port: ?[]const u8 = null;

/// The program ended: a debugger is told how.
fn ended(vm: *VM, code: u8) void {
    if (vm.debugger) |d| d.finish(code);
}

/// Prints the pending slang error and exits.
fn fail(vm: *VM) noreturn {
    vm.flush();
    // a profile of a run that failed is still a profile
    if (vm.profiler) |p| p.finish();
    ended(vm, 1);
    isolates.printUnjoined(vm.io);
    var e = vm.takeError();
    var w = stderr(vm.io);
    e.write(&w.interface) catch {};
    w.interface.flush() catch {};
    e.deinit(vm.gpa);
    std.process.exit(1);
}

fn failMsg(vm: *VM, comptime fmt: []const u8, a: anytype) noreturn {
    vm.setError(fmt, a);
    fail(vm);
}

fn readFile(vm: *VM, path: []const u8) []u8 {
    return std.Io.Dir.cwd().readFileAlloc(vm.io, path, vm.gpa, .unlimited) catch |e| {
        failMsg(vm, "cannot read {s}: {t}", .{ path, e });
    };
}

fn loadFile(vm: *VM, path: []const u8) *Closure {
    return boot.loadFile(vm, path) catch fail(vm);
}

fn run(init: std.process.Init, path: []const u8, args: []const []const u8, explain: bool, profile: ?[]const u8) void {
    const vm = newVM(init, args);
    defer vm.destroy();
    if (profile) |p| {
        if (vm.profiler == null) vm.profiler = vm_mod.Profiler.create(vm.backing, vm.io, p);
    }
    if (explain) {
        const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
        compiler.table.set(vm.gpa, vm.str("explain"), .{ .bool = true });
    }
    const cl = loadFile(vm, path);
    if (builtin.os.tag == .emscripten) return web.start(vm, cl);
    _ = vm.call(.{ .function = cl }, &.{}) catch fail(vm);
    vm.flush();
    ended(vm, 0);
    isolates.finish(vm, 0);
}

/// In the browser (Emscripten) a program runs as a coroutine: when it yields
/// (slang/web's frame(), which raylib's end_drawing calls) main hands the
/// browser control, and each animation frame resumes it. The VM outlives
/// main: emscripten_set_main_loop does not return.
const web = if (builtin.os.tag == .emscripten) struct {
    extern fn emscripten_set_main_loop(f: *const fn () callconv(.c) void, fps: c_int, simulate_infinite_loop: c_int) void;
    extern fn emscripten_cancel_main_loop() void;
    extern fn emscripten_force_exit(code: c_int) noreturn;
    var the_vm: *VM = undefined;
    var program: i64 = 0;

    fn start(vm: *VM, cl: *vm_mod.Closure) void {
        const co = vm.newThread(cl);
        the_vm = vm;
        program = vm.makeRef(.{ .thread = co });
        _ = co.resumeCo(&.{}) catch fail(vm);
        vm.flush();
        if (co.status == .dead) return ended(vm, 0);
        emscripten_set_main_loop(frame, 0, 1);
    }

    fn frame() callconv(.c) void {
        const vm = the_vm;
        const co = vm.getRef(program).thread;
        _ = co.resumeCo(&.{}) catch {
            emscripten_cancel_main_loop();
            fail(vm);
        };
        vm.flush();
        if (co.status == .dead) {
            emscripten_cancel_main_loop();
            emscripten_force_exit(0);
        }
    }
} else struct {};

/// Runs the program bundled into this executable (slang build): its entry
/// module, with every argument as its own.
fn runBundled(init: std.process.Init, b: *const bundle.Bundle) u8 {
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(init.gpa);
    // (WASI needs the allocator; elsewhere it is not used)
    var it = init.minimal.args.iterateAllocator(init.gpa) catch oom();
    defer it.deinit();
    _ = it.next();
    while (it.next()) |a| rest.append(init.gpa, a) catch oom();
    const vm = newVM(init, rest.items);
    defer vm.destroy();
    const entry = b.index.lookup(.module, bundle_format.main_module) orelse failMsg(vm, "the bundle has no program", .{});
    const cl = vm.loadBytes(entry.data) catch fail(vm);
    _ = vm.call(.{ .function = cl }, &.{}) catch fail(vm);
    vm.flush();
    isolates.finish(vm, 0);
    return 0;
}

/// Compiles and runs every *test.slang file in dir (or the one file given),
/// then runs the collected tests with slang/test, which reads the options
/// (--json, --only) from the arguments; the exit code is 1 when a test failed.
fn runTests(init: std.process.Init, args: []const []const u8) u8 {
    var target: []const u8 = "./test";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--only")) {
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            target = args[i];
        }
    }
    const vm = newVM(init, args);
    defer vm.destroy();
    if (std.mem.endsWith(u8, target, ".slang")) {
        const cl = loadFile(vm, target);
        _ = vm.call(.{ .function = cl }, &.{}) catch fail(vm);
    } else {
        const names = oslib.listDir(vm, target) catch |e| failMsg(vm, "cannot list {s}: {t}", .{ target, e });
        defer oslib.freeNames(vm, names);
        for (names) |name| {
            if (!std.mem.endsWith(u8, name, "test.slang")) continue;
            const path = std.fmt.allocPrint(vm.gpa, "{s}/{s}", .{ target, name }) catch oom();
            defer vm.gpa.free(path);
            const cl = loadFile(vm, path);
            _ = vm.call(.{ .function = cl }, &.{}) catch fail(vm);
        }
    }
    const runner = vm.call(vm.getGlobal("compile"), &.{
        vm.str("\n\t\treturn require(\"slang/test\").run_cli(args())\n\t"),
        vm.str("test runner"),
    }) catch fail(vm);
    const failed = vm.call(runner, &.{}) catch fail(vm);
    vm.flush();
    const code: u8 = if (failed.truthy()) 1 else 0;
    ended(vm, code);
    isolates.finish(vm, code);
    return code;
}

fn printError(vm: *VM) void {
    var e = vm.takeError();
    defer e.deinit(vm.gpa);
    const out = vm.out();
    out.print("error: {s}\n", .{e.message}) catch {};
    if (e.loc) |l| out.print("  at {s}:{d}:{d}\n", .{ l.origin, l.line, l.column }) catch {};
}

/// Reads statements or expressions from stdin and evaluates them.
fn repl(init: std.process.Init) void {
    const vm = newVM(init, &.{});
    defer vm.destroy();
    const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
    const compile_repl = compiler.table.getName("compile_repl");
    const out = vm.out();
    out.writeAll("Slang REPL (exit or ctrl-d to quit)\n") catch {};
    while (true) {
        out.writeAll(">>> ") catch {};
        vm.flush();
        const line_opt = vm.stdin.interface.takeDelimiter('\n') catch null;
        const line = std.mem.trimEnd(u8, line_opt orelse break, "\r\n");
        if (std.mem.eql(u8, line, "exit")) break;
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const f = vm.call(compile_repl, &.{vm.str(line)}) catch {
            printError(vm);
            continue;
        };
        const res = vm.call(f, &.{}) catch {
            printError(vm);
            continue;
        };
        vm_mod.format.writeValue(out, res) catch {};
        out.writeByte('\n') catch {};
    }
    vm.flush();
}

/// Prints a file as core slang source (compiler.expand_file).
fn expandFile(init: std.process.Init, path: []const u8) void {
    const vm = newVM(init, &.{});
    defer vm.destroy();
    const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
    const res = vm.call(compiler.table.getName("expand_file"), &.{vm.str(path)}) catch fail(vm);
    const text = res.asBytes() orelse failMsg(vm, "expand_file did not return a string", .{});
    vm.out().writeAll(text) catch {};
    vm.flush();
}

/// Runs a tool written in slang: module.main(args) returns the exit code.
fn toolMain(init: std.process.Init, module: []const u8, args: []const []const u8) u8 {
    const vm = newVM(init, args);
    defer vm.destroy();
    const tool = vm.call(vm.getGlobal("require"), &.{vm.str(module)}) catch fail(vm);
    const list = vm.newTable(args.len, 0);
    for (args) |a| list.append(vm.gpa, vm.str(a));
    const res = vm.call(tool.table.getName("main"), &.{.{ .table = list }}) catch fail(vm);
    vm.flush();
    const code: u8 = switch (res) {
        .int => |c| @intCast(c),
        else => 0,
    };
    ended(vm, code);
    isolates.finish(vm, code);
    return code;
}

/// Prints the tokens and diagnostics of a file as JSON (compiler.highlight_json).
fn highlightFile(init: std.process.Init, path: []const u8, check: bool) void {
    const vm = newVM(init, &.{});
    defer vm.destroy();
    const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
    const res = vm.call(compiler.table.getName("highlight_json"), &.{ vm.str(path), Value.fromBool(check) }) catch fail(vm);
    const text = res.asBytes() orelse failMsg(vm, "highlight_json did not return a string", .{});
    vm.out().writeAll(text) catch {};
    vm.out().writeByte('\n') catch {};
    vm.flush();
}

/// Compiles a file with the self-hosted compiler, as `slang run` would (its
/// project and dialect apply).
fn compileSource(vm: *VM, path: []const u8, origin_opt: ?[]const u8) *Proto {
    const origin = origin_opt orelse stripSuffix(path, ".slang");
    const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
    const res = vm.call(compiler.table.getName("compile_file"), &.{ vm.str(path), vm.str(origin) }) catch fail(vm);
    vm.flush();
    const cl = res.asClosure() orelse failMsg(vm, "compile did not return a slang function", .{});
    return cl.proto orelse failMsg(vm, "compile did not return a slang function", .{});
}

/// Compiles a .slang file to .slb.
fn compileFile(init: std.process.Init, args: []const []const u8) void {
    const path = args[0];
    var out_path: ?[]const u8 = null;
    var origin: ?[]const u8 = null;
    var strip = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            i += 1;
            if (i >= args.len) usage(init.io);
            out_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--origin")) {
            i += 1;
            if (i >= args.len) usage(init.io);
            origin = args[i];
        } else if (std.mem.eql(u8, args[i], "--strip")) {
            strip = true;
        } else {
            usage(init.io);
        }
    }
    const vm = newVM(init, &.{});
    defer vm.destroy();
    const p = compileSource(vm, path, origin);
    const bytes = vm_mod.slb.encode(vm.gpa, p, strip);
    defer vm.gpa.free(bytes);
    const out = out_path orelse std.fmt.allocPrint(vm.gpa, "{s}.slb", .{stripSuffix(path, ".slang")}) catch oom();
    std.Io.Dir.cwd().writeFile(vm.io, .{ .sub_path = out, .data = bytes }) catch |e| failMsg(vm, "cannot write {s}: {t}", .{ out, e });
}

fn disasmFile(init: std.process.Init, path: []const u8) void {
    const vm = newVM(init, &.{});
    defer vm.destroy();
    var p: *Proto = undefined;
    if (std.mem.endsWith(u8, path, ".slang")) {
        p = compileSource(vm, path, null);
    } else {
        const data = readFile(vm, path);
        defer vm.gpa.free(data);
        p = vm_mod.slb.decode(vm, data) catch |e| failMsg(vm, "{s}", .{vm_mod.slb.errorMessage(e)});
    }
    vm_mod.disasm.disassemble(vm.out(), p) catch {};
    vm.flush();
}
