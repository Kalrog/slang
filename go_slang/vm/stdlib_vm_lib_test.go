package slang_vm

import "testing"

// makeSlangClosure builds a closure with a named upvalue for testing vm introspection.
func makeSlangClosureWithUpvalue(name string, initialVal Value) *Closure {
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Upvalues:        []UpvalueDef{{Name: name, Index: 0, IsLocal: false}},
		Instructions:    []uint32{uint32(opReturn)},
	}
	holder := &UpvalueHolder{value: initialVal}
	return &Closure{
		Prototype: proto,
		Upvalues:  []*UpvalueHolder{holder},
	}
}

func TestVMModule(t *testing.T) {
	m := buildVMModule()

	t.Run("upvalueNames", func(t *testing.T) {
		cl := makeSlangClosureWithUpvalue("myVar", IntVal(42))
		got := callModuleFn(t, m, "upvalueNames", ClosureVal(cl))
		if got.Type != TypeTable {
			t.Fatalf("upvalueNames returned %s, want table", got.TypeName())
		}
		tbl := got.Obj.(*SlangTable)
		if tbl.Length() != 1 {
			t.Fatalf("upvalueNames len = %d, want 1", tbl.Length())
		}
		name := tbl.Get(IntVal(0)).Obj.(string)
		if name != "myVar" {
			t.Errorf("upvalueNames[0] = %q, want %q", name, "myVar")
		}
	})

	t.Run("getUpvalue", func(t *testing.T) {
		cl := makeSlangClosureWithUpvalue("x", IntVal(99))
		got := callModuleFn(t, m, "getUpvalue", ClosureVal(cl), StringVal("x"))
		if got.Type != TypeInt || got.IVal != 99 {
			t.Errorf("getUpvalue = %v, want int 99", got)
		}
	})

	t.Run("getUpvalue_not_found", func(t *testing.T) {
		cl := makeSlangClosureWithUpvalue("x", IntVal(1))
		got := callModuleFn(t, m, "getUpvalue", ClosureVal(cl), StringVal("missing"))
		if got.Type != TypeNil {
			t.Errorf("getUpvalue missing = %s, want nil", got.TypeName())
		}
	})

	t.Run("setUpvalue", func(t *testing.T) {
		cl := makeSlangClosureWithUpvalue("counter", IntVal(0))
		// Set it
		vm := NewVM()
		setFn := m.Get(StringVal("setUpvalue"))
		f := vm.frame
		f.stack[0] = setFn
		f.stack[1] = ClosureVal(cl)
		f.stack[2] = StringVal("counter")
		f.stack[3] = IntVal(77)
		f.top = 4
		vm.prepareCall(3)
		vm.run()
		// Verify
		got := cl.Upvalues[0].Get()
		if got.Type != TypeInt || got.IVal != 77 {
			t.Errorf("after setUpvalue, counter = %v, want int 77", got)
		}
	})

	t.Run("upvalueNames_native_closure", func(t *testing.T) {
		// Native closures have no upvalues
		native := ClosureVal(&Closure{GoFunc: func(vm *VM) bool { return false }, Upvalues: make([]*UpvalueHolder, 0)})
		got := callModuleFn(t, m, "upvalueNames", native)
		tbl := got.Obj.(*SlangTable)
		if tbl.Length() != 0 {
			t.Errorf("native closure upvalueNames len = %d, want 0", tbl.Length())
		}
	})
}
