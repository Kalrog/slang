// Command slang is the slang interpreter.
package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime/debug"
	"runtime/pprof"
	"strings"

	"slang/boot"
	"slang/stdlib"
	"slang/vm"
)

func usage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  slang run [--explain] <file.slang|file.slb> [args...]")
	fmt.Fprintln(os.Stderr, "  slang test [dir]            run every *test.slang file in dir (default ./test)")
	fmt.Fprintln(os.Stderr, "  slang repl")
	fmt.Fprintln(os.Stderr, "  slang compile <file.slang> [-o out.slb] [--origin name] [--strip]")
	fmt.Fprintln(os.Stderr, "  slang disasm <file.slb|file.slang>")
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	// Interpreters allocate many small short-lived objects; trading memory for
	// fewer collections is a clear win. GOGC in the environment still wins.
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(400)
	}
	// SLANG_CPUPROFILE=file writes a CPU profile for `go tool pprof`.
	if prof := os.Getenv("SLANG_CPUPROFILE"); prof != "" {
		f, err := os.Create(prof)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		pprof.StartCPUProfile(f)
		defer pprof.StopCPUProfile()
	}
	// SLANG_CALLPROFILE=1 prints the most called slang functions at exit.
	if os.Getenv("SLANG_CALLPROFILE") != "" {
		vm.CallProfile = map[*vm.FunctionProto]int{}
		defer vm.PrintCallProfile(os.Stderr, 40)
	}
	switch os.Args[1] {
	case "run":
		rest := os.Args[2:]
		explain := false
		if len(rest) > 0 && rest[0] == "--explain" {
			explain = true
			rest = rest[1:]
		}
		if len(rest) < 1 {
			usage()
		}
		run(rest[0], rest[1:], explain)
	case "test":
		dir := "./test"
		if len(os.Args) > 2 {
			dir = os.Args[2]
		}
		runTests(dir)
	case "repl":
		repl()
	case "compile":
		if len(os.Args) < 3 {
			usage()
		}
		compileFile(os.Args[2:])
	case "disasm":
		if len(os.Args) < 3 {
			usage()
		}
		disasm(os.Args[2])
	default:
		usage()
	}
}

func newVM(args []string) (*vm.VM, *bufio.Writer) {
	v := vm.New()
	v.Args = args
	v.Embedded = boot.FS
	out := bufio.NewWriterSize(os.Stdout, 1<<16)
	v.Stdout = out
	stdlib.Open(v)
	if err := stdlib.Boot(v); err != nil {
		fail(v, err)
	}
	return v, out
}

func fail(v *vm.VM, err error) {
	v.Flush()
	if e, ok := err.(*vm.Error); ok {
		fmt.Fprintf(os.Stderr, "error: %s\n", e.Message)
		if e.Loc != nil {
			fmt.Fprintf(os.Stderr, "  at %s\n", e.Loc)
		}
		if e.Trace != "" {
			fmt.Fprintln(os.Stderr, e.Trace)
		}
	} else {
		fmt.Fprintln(os.Stderr, "error:", err)
	}
	os.Exit(1)
}

// loadFile loads the main file of a program: bytecode as is, source through
// the compiler's load_main (project file, dialects, `extension global`).
func loadFile(v *vm.VM, path string) *vm.Closure {
	if strings.HasSuffix(path, ".slb") {
		data, err := os.ReadFile(path)
		if err != nil {
			fail(v, err)
		}
		cl, err := v.LoadBytes(data)
		if err != nil {
			fail(v, err)
		}
		return cl
	}
	if compile := v.GetGlobal("compile"); !compile.IsNull() {
		compiler, err := v.Call(v.GetGlobal("require"), vm.String("slang/compiler"))
		if err != nil {
			fail(v, err)
		}
		res, err := v.Call(compiler.AsTable().GetStr("load_main"), vm.String(path))
		if err != nil {
			fail(v, err)
		}
		cl := res.AsFunction()
		if cl == nil {
			fail(v, fmt.Errorf("compile did not return a function"))
		}
		return cl
	}
	slb := strings.TrimSuffix(path, ".slang") + ".slb"
	if data, err := os.ReadFile(slb); err == nil {
		cl, err := v.LoadBytes(data)
		if err != nil {
			fail(v, err)
		}
		return cl
	}
	fail(v, fmt.Errorf("no compiler available and %s not found; compile %s with tool/stage0.dart first", slb, path))
	return nil
}

func run(path string, args []string, explain bool) {
	v, out := newVM(args)
	if explain {
		compiler, err := v.Call(v.GetGlobal("require"), vm.String("slang/compiler"))
		if err != nil {
			fail(v, err)
		}
		compiler.AsTable().SetStr("explain", vm.True)
	}
	cl := loadFile(v, path)
	_, err := v.Call(vm.FunctionValue(cl))
	out.Flush()
	if err != nil {
		fail(v, err)
	}
	v.Flush()
}

// runTests compiles and runs every *test.slang file in dir, then runs the
// collected tests with slang/test.
func runTests(dir string) {
	v, out := newVM(nil)
	entries, err := os.ReadDir(dir)
	if err != nil {
		fail(v, err)
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), "test.slang") {
			continue
		}
		path := dir + "/" + e.Name()
		cl := loadFile(v, path)
		if _, err := v.Call(vm.FunctionValue(cl)); err != nil {
			fail(v, err)
		}
	}
	runner, err := v.Call(v.GetGlobal("compile"), vm.String(`
		local test = require("slang/test")
		test.run()
	`), vm.String("test runner"))
	if err != nil {
		fail(v, err)
	}
	_, err = v.Call(runner)
	out.Flush()
	if err != nil {
		fail(v, err)
	}
}

// repl reads statements or expressions from stdin and evaluates them.
func repl() {
	v, out := newVM(nil)
	compiler, err := v.Call(v.GetGlobal("require"), vm.String("slang/compiler"))
	if err != nil {
		fail(v, err)
	}
	compileRepl := compiler.AsTable().GetStr("compile_repl")
	fmt.Fprintln(out, "Slang REPL (exit or ctrl-d to quit)")
	for {
		fmt.Fprint(out, ">>> ")
		out.Flush()
		line, rerr := v.Stdin.ReadString('\n')
		line = strings.TrimRight(line, "\r\n")
		if line == "exit" || (rerr != nil && line == "") {
			break
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		fn, cerr := v.Call(compileRepl, vm.String(line))
		if cerr != nil {
			printError(out, cerr)
			continue
		}
		res, cerr := v.Call(fn)
		if cerr != nil {
			printError(out, cerr)
			continue
		}
		fmt.Fprintln(out, res.String())
	}
	out.Flush()
}

func printError(out *bufio.Writer, err error) {
	if e, ok := err.(*vm.Error); ok {
		fmt.Fprintln(out, "error:", e.Message)
		if e.Loc != nil {
			fmt.Fprintln(out, "  at", e.Loc)
		}
		return
	}
	fmt.Fprintln(out, "error:", err)
}

// compileSource compiles source text with the self-hosted compiler.
func compileSource(v *vm.VM, out *bufio.Writer, path, origin string) *vm.FunctionProto {
	src, err := os.ReadFile(path)
	if err != nil {
		fail(v, err)
	}
	if origin == "" {
		origin = strings.TrimSuffix(path, ".slang")
	}
	res, err := v.Call(v.GetGlobal("compile"), vm.String(string(src)), vm.String(origin))
	out.Flush()
	if err != nil {
		fail(v, err)
	}
	cl := res.AsFunction()
	if cl == nil || cl.Proto == nil {
		fail(v, fmt.Errorf("compile did not return a slang function"))
	}
	return cl.Proto
}

// compileFile compiles a .slang file to .slb.
func compileFile(args []string) {
	path := args[0]
	out := strings.TrimSuffix(path, ".slang") + ".slb"
	origin := ""
	strip := false
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "-o":
			i++
			if i >= len(args) {
				usage()
			}
			out = args[i]
		case "--origin":
			i++
			if i >= len(args) {
				usage()
			}
			origin = args[i]
		case "--strip":
			strip = true
		default:
			usage()
		}
	}
	v, bufout := newVM(nil)
	p := compileSource(v, bufout, path, origin)
	if err := os.WriteFile(out, vm.Encode(p, strip), 0o644); err != nil {
		fail(v, err)
	}
}

func disasm(path string) {
	var p *vm.FunctionProto
	if strings.HasSuffix(path, ".slang") {
		v, bufout := newVM(nil)
		p = compileSource(v, bufout, path, "")
	} else {
		data, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		p, err = vm.Decode(data)
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
	}
	fmt.Print(vm.Disassemble(p))
}
