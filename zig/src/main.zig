//! The slang command line: run, test, repl, compile, disasm.

const std = @import("std");
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

// The C API must be compiled and exported even though nothing in the CLI
// calls it: native extensions resolve the slang_* symbols against the
// executable.
comptime {
    _ = @import("capi.zig");
}

var stderr_buf: [4096]u8 = undefined;

fn stderr(io: std.Io) std.Io.File.Writer {
    return std.Io.File.stderr().writerStreaming(io, &stderr_buf);
}

fn usage(io: std.Io) noreturn {
    var w = stderr(io);
    w.interface.writeAll(
        \\usage:
        \\  slang run [--explain] <file.slang|file.slb> [args...]
        \\  slang test [dir]            run every *test.slang file in dir (default ./test)
        \\  slang repl
        \\  slang compile <file.slang> [-o out.slb] [--origin name] [--strip]
        \\  slang disasm <file.slb|file.slang>
        \\  slang highlight <file>       print the tokens and parse errors of a file as JSON
        \\  slang expand <file>          print a file as slang source after its extensions were applied
        \\
    ) catch {};
    w.interface.flush() catch {};
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var it = init.minimal.args.iterate();
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
        if (run_args.len > 0 and std.mem.eql(u8, run_args[0], "--explain")) {
            explain = true;
            run_args = run_args[1..];
        }
        if (run_args.len < 1) usage(io);
        run(init, run_args[0], run_args[1..], explain);
    } else if (std.mem.eql(u8, cmd, "test")) {
        runTests(init, if (args.len > 0) args[0] else "./test");
    } else if (std.mem.eql(u8, cmd, "repl")) {
        repl(init);
    } else if (std.mem.eql(u8, cmd, "compile")) {
        if (args.len < 1) usage(io);
        compileFile(init, args);
    } else if (std.mem.eql(u8, cmd, "highlight")) {
        if (args.len < 1) usage(io);
        highlightFile(init, args[0]);
    } else if (std.mem.eql(u8, cmd, "expand")) {
        if (args.len < 1) usage(io);
        expandFile(init, args[0]);
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
    return vm;
}

/// Prints the pending slang error and exits.
fn fail(vm: *VM) noreturn {
    vm.flush();
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

fn run(init: std.process.Init, path: []const u8, args: []const []const u8, explain: bool) void {
    const vm = newVM(init, args);
    defer vm.destroy();
    if (explain) {
        const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
        compiler.table.set(vm.gpa, vm.str("explain"), .{ .bool = true });
    }
    const cl = loadFile(vm, path);
    _ = vm.call(.{ .function = cl }, &.{}) catch fail(vm);
    vm.flush();
}

/// Compiles and runs every *test.slang file in dir, then runs the collected
/// tests with slang/test.
fn runTests(init: std.process.Init, dir: []const u8) void {
    const vm = newVM(init, &.{});
    defer vm.destroy();
    const names = oslib.listDir(vm, dir) catch |e| failMsg(vm, "cannot list {s}: {t}", .{ dir, e });
    defer oslib.freeNames(vm, names);
    for (names) |name| {
        if (!std.mem.endsWith(u8, name, "test.slang")) continue;
        const path = std.fmt.allocPrint(vm.gpa, "{s}/{s}", .{ dir, name }) catch oom();
        defer vm.gpa.free(path);
        const cl = loadFile(vm, path);
        _ = vm.call(.{ .function = cl }, &.{}) catch fail(vm);
    }
    const runner = vm.call(vm.getGlobal("compile"), &.{
        vm.str("\n\t\tlocal test = require(\"slang/test\")\n\t\ttest.run()\n\t"),
        vm.str("test runner"),
    }) catch fail(vm);
    _ = vm.call(runner, &.{}) catch fail(vm);
    vm.flush();
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

/// Prints the tokens and diagnostics of a file as JSON (compiler.highlight_json).
fn highlightFile(init: std.process.Init, path: []const u8) void {
    const vm = newVM(init, &.{});
    defer vm.destroy();
    const compiler = vm.call(vm.getGlobal("require"), &.{vm.str("slang/compiler")}) catch fail(vm);
    const res = vm.call(compiler.table.getName("highlight_json"), &.{vm.str(path)}) catch fail(vm);
    const text = res.asBytes() orelse failMsg(vm, "highlight_json did not return a string", .{});
    vm.out().writeAll(text) catch {};
    vm.out().writeByte('\n') catch {};
    vm.flush();
}

/// Compiles source text with the self-hosted compiler.
fn compileSource(vm: *VM, path: []const u8, origin_opt: ?[]const u8) *Proto {
    const src = readFile(vm, path);
    defer vm.gpa.free(src);
    const origin = origin_opt orelse stripSuffix(path, ".slang");
    const res = vm.call(vm.getGlobal("compile"), &.{ vm.str(src), vm.str(origin) }) catch fail(vm);
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
