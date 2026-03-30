package slang_vm

import "testing"

func TestPegModule(t *testing.T) {
	vm := NewVM()
	RegisterStdlib(vm, "")
	mod := buildPegModule(vm)

	// callMod calls a module function by name with the given args and returns
	// the top-of-stack result. Resets the stack before each call.
	callMod := func(name string, args ...Value) Value {
		vm.frame.top = 0
		fn := mod.Get(StringVal(name))
		vm.Push(fn)
		for _, a := range args {
			vm.Push(a)
		}
		vm.Call(len(args))
		return vm.frame.stack[vm.frame.top-1]
	}

	t.Run("string_match", func(t *testing.T) {
		parserVal := callMod("string", StringVal("hello"))
		if parserVal.Type != TypeUserdata {
			t.Fatalf("peg.string returned %s, want userdata", parserVal.TypeName())
		}

		res := callMod("parse", parserVal, StringVal("hello"))
		if res.Type != TypeTable {
			t.Fatalf("peg.parse returned %s, want table", res.TypeName())
		}
		tbl := res.Obj.(*SlangTable)
		if !tbl.Get(StringVal("ok")).ToBool() {
			t.Error("parse should succeed for matching input")
		}
		val := tbl.Get(StringVal("value"))
		if val.Type != TypeString || val.Obj.(string) != "hello" {
			t.Errorf("value = %v, want StringVal(\"hello\")", val)
		}
		pos := tbl.Get(StringVal("position"))
		if pos.Type != TypeInt || pos.IVal != 5 {
			t.Errorf("position = %v, want 5", pos)
		}
	})

	t.Run("string_no_match", func(t *testing.T) {
		parserVal := callMod("string", StringVal("hello"))
		res := callMod("parse", parserVal, StringVal("world"))
		tbl := res.Obj.(*SlangTable)
		if tbl.Get(StringVal("ok")).ToBool() {
			t.Error("parse should fail for non-matching input")
		}
		if tbl.Get(StringVal("error")).Type != TypeString {
			t.Error("error field should be a string on failure")
		}
	})

	t.Run("pattern_match", func(t *testing.T) {
		parserVal := callMod("pattern", StringVal("[0-9]+"))
		res := callMod("parse", parserVal, StringVal("123abc"))
		tbl := res.Obj.(*SlangTable)
		if !tbl.Get(StringVal("ok")).ToBool() {
			t.Error("pattern parse should succeed")
		}
		val := tbl.Get(StringVal("value"))
		if val.Type != TypeString || val.Obj.(string) != "123" {
			t.Errorf("value = %v, want \"123\"", val)
		}
	})

	t.Run("seq_and_keep", func(t *testing.T) {
		p1 := callMod("string", StringVal("foo"))
		p2 := callMod("string", StringVal("bar"))
		seqParser := callMod("seq", p1, p2)
		res := callMod("parse", seqParser, StringVal("foobar"))
		tbl := res.Obj.(*SlangTable)
		if !tbl.Get(StringVal("ok")).ToBool() {
			t.Error("seq parse should succeed")
		}
		// Keep index 1 (second element, 0-indexed).
		keepParser := callMod("keep", seqParser, IntVal(1))
		keepRes := callMod("parse", keepParser, StringVal("foobar"))
		keepTbl := keepRes.Obj.(*SlangTable)
		if !keepTbl.Get(StringVal("ok")).ToBool() {
			t.Error("keep parse should succeed")
		}
		kept := keepTbl.Get(StringVal("value"))
		if kept.Type != TypeString || kept.Obj.(string) != "bar" {
			t.Errorf("keep value = %v, want \"bar\"", kept)
		}
	})

	t.Run("choice", func(t *testing.T) {
		p1 := callMod("string", StringVal("foo"))
		p2 := callMod("string", StringVal("bar"))
		choiceParser := callMod("choice", p1, p2)

		res1 := callMod("parse", choiceParser, StringVal("foo"))
		if !res1.Obj.(*SlangTable).Get(StringVal("ok")).ToBool() {
			t.Error("choice should match first alternative")
		}
		res2 := callMod("parse", choiceParser, StringVal("bar"))
		if !res2.Obj.(*SlangTable).Get(StringVal("ok")).ToBool() {
			t.Error("choice should match second alternative")
		}
		res3 := callMod("parse", choiceParser, StringVal("baz"))
		if res3.Obj.(*SlangTable).Get(StringVal("ok")).ToBool() {
			t.Error("choice should fail when neither alternative matches")
		}
	})

	t.Run("map_with_closure", func(t *testing.T) {
		// Register a native Go function as the mapper (doubles the string).
		vm.RegisterGoFunction("_peg_test_double", func(vm *VM) bool {
			s := vm.GetStringArg(0)
			vm.Push(StringVal(s + s))
			return true
		})
		mapperCl := vm.globals.Get(StringVal("_peg_test_double"))

		parserVal := callMod("string", StringVal("hi"))
		mappedParser := callMod("map", parserVal, mapperCl)
		if mappedParser.Type != TypeUserdata {
			t.Fatalf("peg.map returned %s, want userdata", mappedParser.TypeName())
		}

		res := callMod("parse", mappedParser, StringVal("hi"))
		tbl := res.Obj.(*SlangTable)
		if !tbl.Get(StringVal("ok")).ToBool() {
			t.Error("mapped parse should succeed")
		}
		val := tbl.Get(StringVal("value"))
		if val.Type != TypeString || val.Obj.(string) != "hihi" {
			t.Errorf("mapped value = %v, want \"hihi\"", val)
		}
	})

	t.Run("token", func(t *testing.T) {
		p := callMod("pattern", StringVal("[a-z]+"))
		tokenParser := callMod("token", p, StringVal("IDENT"))
		res := callMod("parse", tokenParser, StringVal("hello"))
		tbl := res.Obj.(*SlangTable)
		if !tbl.Get(StringVal("ok")).ToBool() {
			t.Error("token parse should succeed")
		}
		val := tbl.Get(StringVal("value"))
		if val.Type != TypeTable {
			t.Fatalf("token value should be table, got %s", val.TypeName())
		}
		tokenTbl := val.Obj.(*SlangTable)
		typ := tokenTbl.Get(StringVal("type"))
		if typ.Type != TypeString || typ.Obj.(string) != "IDENT" {
			t.Errorf("token type = %v, want \"IDENT\"", typ)
		}
		tokVal := tokenTbl.Get(StringVal("value"))
		if tokVal.Type != TypeString || tokVal.Obj.(string) != "hello" {
			t.Errorf("token value = %v, want \"hello\"", tokVal)
		}
	})

	t.Run("star", func(t *testing.T) {
		p := callMod("string", StringVal("a"))
		starParser := callMod("star", p)
		res := callMod("parse", starParser, StringVal("aaab"))
		tbl := res.Obj.(*SlangTable)
		if !tbl.Get(StringVal("ok")).ToBool() {
			t.Error("star parse should succeed (matches zero or more)")
		}
		val := tbl.Get(StringVal("value"))
		if val.Type != TypeTable {
			t.Fatalf("star value should be table, got %s", val.TypeName())
		}
		items := val.Obj.(*SlangTable)
		if items.Length() != 3 {
			t.Errorf("star matched %d items, want 3", items.Length())
		}
	})

	t.Run("start_end", func(t *testing.T) {
		startP := callMod("start")
		endP := callMod("end")

		resStart := callMod("parse", startP, StringVal(""))
		if !resStart.Obj.(*SlangTable).Get(StringVal("ok")).ToBool() {
			t.Error("start should succeed at position 0")
		}
		resEnd := callMod("parse", endP, StringVal(""))
		if !resEnd.Obj.(*SlangTable).Get(StringVal("ok")).ToBool() {
			t.Error("end should succeed on empty input")
		}
	})
}
