package slang_vm

import "testing"

func TestBitwiseModule(t *testing.T) {
	mod := buildBitwiseModule()
	call := func(name string, a, b int64) int64 {
		t.Helper()
		vm := NewVM()
		fn := mod.Get(StringVal(name))
		vm.Push(fn)
		vm.Push(IntVal(a))
		vm.Push(IntVal(b))
		vm.Call(2)
		return vm.frame.stack[vm.frame.top-1].IVal
	}

	tests := []struct {
		op   string
		a, b int64
		want int64
	}{
		{"band", 0b1010, 0b1100, 0b1000},
		{"bor", 0b1010, 0b0101, 0b1111},
		{"bxor", 0b1010, 0b1100, 0b0110},
		{"lshift", 1, 3, 8},
		{"rshift", 16, 2, 4},
	}
	for _, tt := range tests {
		got := call(tt.op, tt.a, tt.b)
		if got != tt.want {
			t.Errorf("%s(%d, %d) = %d, want %d", tt.op, tt.a, tt.b, got, tt.want)
		}
	}
}

func TestInvoke(t *testing.T) {
	vm := NewVM()
	// Register a native fn: returns arg * 2
	vm.RegisterGoFunction("double", func(vm *VM) bool {
		n := vm.GetIntArg(0)
		vm.Push(IntVal(n * 2))
		return true
	})
	doubleCl := vm.globals.Get(StringVal("double"))

	result, err := vm.Invoke(doubleCl, []Value{IntVal(21)})
	if err != nil {
		t.Fatalf("Invoke returned error: %v", err)
	}
	if result.Type != TypeInt || result.IVal != 42 {
		t.Errorf("expected 42, got %+v", result)
	}
}

func TestInvokeSlang(t *testing.T) {
	// Slang proto: return arg[0] + 1
	// stack[0] = arg, maxVarStackSize=4
	// loadBool(skip=0, b=0) not useful; instead use push(0) + loadConst(1) + add + return
	// Simpler: just use loadConst(1), then push(arg at idx 0), add, return.
	// Arg is at stack[0].
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Nargs:           1,
		Instructions: []uint32{
			encPushRel(-8), // push stack[0] (arg, relative to top=8 after setTop: top-8 = index 0)
			encLC(0),       // push const 1
			uint32(opAdd),
			uint32(opReturn),
		},
		Constants: []Value{IntVal(1)},
	}
	vm := NewVM()
	cl := &Closure{Prototype: proto, Upvalues: make([]*UpvalueHolder, 0)}
	result, err := vm.Invoke(ClosureVal(cl), []Value{IntVal(10)})
	if err != nil {
		t.Fatalf("Invoke error: %v", err)
	}
	if result.Type != TypeInt || result.IVal != 11 {
		t.Errorf("expected 11, got %+v", result)
	}
}

func TestInvokeError(t *testing.T) {
	vm := NewVM()
	vm.RegisterGoFunction("boom", func(vm *VM) bool {
		panic(&SlangException{Message: "test error"})
	})
	boomCl := vm.globals.Get(StringVal("boom"))

	result, err := vm.Invoke(boomCl, nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if err.Error() != "test error" {
		t.Errorf("expected 'test error', got %q", err.Error())
	}
	if result.Type != TypeNil {
		t.Errorf("expected nil result on error, got %+v", result)
	}
	// VM frame stack should be clean (savedTop restored)
	if vm.frame.top != 0 {
		t.Errorf("expected frame top=0 after error, got %d", vm.frame.top)
	}
}
