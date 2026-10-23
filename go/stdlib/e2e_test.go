package stdlib_test

import (
	"bytes"
	"strings"
	"testing"

	"slang/boot"
	"slang/stdlib"
	"slang/vm"
)

// newVM boots a VM with the embedded seed (stdlib + compiler).
func newVM(t *testing.T) (*vm.VM, *bytes.Buffer) {
	t.Helper()
	v := vm.New()
	v.Embedded = boot.FS
	out := &bytes.Buffer{}
	v.Stdout = out
	stdlib.Open(v)
	if err := stdlib.Boot(v); err != nil {
		t.Fatalf("boot: %v", err)
	}
	return v, out
}

// eval compiles and runs a chunk and returns its return value.
func eval(t *testing.T, v *vm.VM, src string) (vm.Value, error) {
	t.Helper()
	fn, err := v.Call(v.GetGlobal("compile"), vm.String(src), vm.String("test"))
	if err != nil {
		t.Fatalf("compile %q: %v", src, err)
	}
	return v.Call(fn)
}

func mustEval(t *testing.T, v *vm.VM, src string) vm.Value {
	t.Helper()
	res, err := eval(t, v, src)
	if err != nil {
		t.Fatalf("eval %q: %v", src, err)
	}
	return res
}

func TestArithmeticSemantics(t *testing.T) {
	v, _ := newVM(t)
	cases := []struct {
		src  string
		want string
	}{
		{"return 1 + 2", "3"},
		{"return 7 / 2", "3.5"},
		{"local a = 1; local b = 2; return a / b", "0.5"},
		{"local a = -7; return a % 3", "2"},
		{"local a = 7; return a % -3", "1"},
		{"local a = -7.5; return a % 2", "0.5"},
		{"local a = 2; return a ^ 10", "1024"},
		{"local a = 2.0; return a ^ 0.5", "1.4142135623730951"},
		{"return 1 == 1.0", "true"},
		{"local a = \"ab\"; return a + \"cd\"", "abcd"},
		{"local a = \"ab\"; return a * 3", "ababab"},
		{"return not 0", "false"},
		{"return not null", "true"},
		{"local x = null; return x or 5", "5"},
		{"local x = false; return x and 5 or 10", "10"},
		{"return 1.0", "1.0"},
		{"return 1000000000000000000000.0 * 1.0", "1e+21"},
		{"return 9223372036854775807 + 1", "-9223372036854775808"},
	}
	for _, c := range cases {
		if got := mustEval(t, v, c.src).String(); got != c.want {
			t.Errorf("%s = %q, want %q", c.src, got, c.want)
		}
	}
}

func TestRuntimeErrorsAreCatchable(t *testing.T) {
	v, _ := newVM(t)
	cases := []struct {
		src     string
		message string
	}{
		{"local x = null; return x.y", "attempt to index a null value"},
		{"local x = 1; return x + \"a\"", "attempt to perform arithmetic"},
		{"local f = 3; return f()", "attempt to call a int value"},
		{"local a = 1; local b = \"x\"; return a < b", "attempt to compare"},
		{"local a = 5; return a % 0", "modulo by zero"},
		{"error(\"boom\")", "boom"},
	}
	for _, c := range cases {
		_, err := eval(t, v, c.src)
		if err == nil || !strings.Contains(err.Error(), c.message) {
			t.Errorf("%s: error = %v, want containing %q", c.src, err, c.message)
		}
		res := mustEval(t, v, "local r = pcall(compile("+quote(c.src)+")); return r")
		if res.AsTable().GetInt(0).String() != "err" {
			t.Errorf("pcall of %s should produce an err result, got %s", c.src, res)
		}
		msg := res.AsTable().GetInt(1).AsTable().GetStr("message").String()
		if !strings.Contains(msg, c.message) {
			t.Errorf("pcall message %q should contain %q", msg, c.message)
		}
	}
}

func quote(s string) string {
	return "\"" + strings.ReplaceAll(strings.ReplaceAll(s, "\\", "\\\\"), "\"", "\\\"") + "\""
}

func TestErrorLocationAndStack(t *testing.T) {
	v, _ := newVM(t)
	_, err := eval(t, v, "local func inner(){\n  error(\"deep\")\n}\nlocal func outer(){\n  inner()\n}\nouter()\n")
	e, ok := err.(*vm.Error)
	if !ok {
		t.Fatalf("want *vm.Error, got %T %v", err, err)
	}
	if e.Loc == nil || e.Loc.Line != 2 || e.Loc.Origin != "test" {
		t.Fatalf("location = %v, want test:2", e.Loc)
	}
	if !strings.Contains(e.Trace, "test:5:") || !strings.Contains(e.Trace, "test:7:") {
		t.Fatalf("trace should mention the callers:\n%s", e.Trace)
	}
}

func TestCoroutines(t *testing.T) {
	v, _ := newVM(t)
	res := mustEval(t, v, `
		local thread = require("slang/thread")
		local co = thread.create(func(a){
			local b = thread.yield(a * 2)
			return a + b
		})
		local first = thread.resume(co, 10)
		local second = thread.resume(co, 5)
		return {first, second, thread.state(co), thread.resume(co)}
	`)
	if got := res.String(); got != "{0: 20, 1: 15, 2: dead, }" {
		t.Fatalf("got %s", got)
	}
	_, err := eval(t, v, `
		local thread = require("slang/thread")
		local co = thread.create(func(){
			local t = {}
			t.meta = {__index: func(tbl, key){ thread.yield(key) }}
			return t.x
		})
		return thread.resume(co)
	`)
	if err == nil || !strings.Contains(err.Error(), "yield across a native call boundary") {
		t.Fatalf("yield inside a metamethod should fail, got %v", err)
	}
	_, err = eval(t, v, `local thread = require("slang/thread"); thread.yield(1)`)
	if err == nil || !strings.Contains(err.Error(), "main thread") {
		t.Fatalf("yield on the main thread should fail, got %v", err)
	}
}

func TestMetatablesAndTypes(t *testing.T) {
	v, _ := newVM(t)
	res := mustEval(t, v, `
		local base = {greet: func(self){ return concat("hi ", self.name) }}
		local obj = {name: "bob"}
		obj.meta = {__index: base, __type: "Person"}
		local log = {}
		local proxy = {}
		proxy.meta = {__newindex: func(t, k, v){ append(log, concat(k, "=", v)) }}
		proxy.a = 1
		proxy.a = 2
		local greeting = obj:greet()
		return {greeting, type(obj), type(base), log, type(func(){}), type(1.5), type(null)}
	`)
	want := "{0: hi bob, 1: Person, 2: table, 3: {0: a=1, 1: a=2, }, 4: function, 5: double, 6: null, }"
	if got := res.String(); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestTablesFromSlang(t *testing.T) {
	v, _ := newVM(t)
	res := mustEval(t, v, `
		local t = {1, 2, 3}
		t[0] = null           // removing an array slot shifts the rest down
		append(t, 4)
		local m = {a: "x", b: "y"}
		m.a = null
		local ks = {}
		for(let local k in keys(m)){ append(ks, k) }
		return {len(t), t == {2, 3, 4}, remove(t, 0), len(t), ks, m.b}
	`)
	want := "{0: 3, 1: true, 2: 2, 3: 2, 4: {0: b, }, 5: y, }"
	if got := res.String(); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}

func TestPrintAndModules(t *testing.T) {
	v, out := newVM(t)
	mustEval(t, v, `
		local m = module{
			func add(a, b){ return a + b }
			local func hidden(){ return 1 }
			value = 42
		}
		print(m.add(1, 2), " ", m.value, " ", m.hidden, " ", m.print, "\n")
		print(1.5, " ", {1, k: 2}, " ", true, "\n")
	`)
	want := "3 42 null null\n1.5 {0: 1, k: 2, } true\n"
	if out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
}

func TestCompileTimeMetaprogramming(t *testing.T) {
	v, _ := newVM(t)
	res := mustEval(t, v, `
		extension {
			local p = require("slang/parser")
			p.add_statement("twice", p.seq(p.keyword("twice"), p.block()):map(func(r){
				return {token: r[0], ast: +{stat: for(local i = 0; i < 2; i = i + 1) -{r[1]}}}
			}))
		}
		local n = 0
		twice { n = n + 1 }
		local ast = +{expr: 1 + 2}
		return {n, ast.type, ast.left.value, compile(+{block: return 40 + 2})()}
	`)
	if got := res.String(); got != "{0: 2, 1: BinOp, 2: 1, 3: 42, }" {
		t.Fatalf("got %s", got)
	}
}

func TestVarargsAndBlocks(t *testing.T) {
	v, _ := newVM(t)
	res := mustEval(t, v, `
		local func f(a, ...rest){ return {a, len(rest), rest[1]} }
		local func g(a, b){ return {a, b} }
		local func h(cb){ return cb() }
		return {f(1), f(1, 2, 3), g(1), g(1, 2, 3), h{ return "block" }}
	`)
	want := "{0: {0: 1, 1: 0, }, 1: {0: 1, 1: 2, 2: 3, }, 2: {0: 1, }, 3: {0: 1, 1: 2, }, 4: block, }"
	if got := res.String(); got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
}
