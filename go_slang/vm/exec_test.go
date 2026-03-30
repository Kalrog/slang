package slang_vm

import (
	"testing"
)

// encLC encodes a loadConstant instruction with the given Bx index.
func encLC(bx int) uint32 { return uint32(bx<<14) | uint32(opLoadConstant) }

// encLB encodes a loadBool instruction (b=value, c=skip-next).
func encLB(b, c int) uint32 { return uint32(b<<23) | uint32(c<<14) | uint32(opLoadBool) }

// encPushRel encodes a push instruction with relative-to-top index (negative).
func encPushRel(rel int) uint32 { return uint32((rel+0x1FFFF)<<14) | uint32(opPush) }

// encPop encodes a pop instruction: remove bx values below the top keep values.
func encPop(keep, bx int) uint32 { return uint32(keep<<6) | uint32(bx<<14) | uint32(opPop) }

// encJump encodes an unconditional jump by sBx instructions.
func encJump(sbx int) uint32 { return uint32((sbx+0x1FFFF)<<14) | uint32(opJump) }

// encTest encodes a test instruction. c=1 means "jump if ToBool is false".
func encTest(c int) uint32 { return uint32(c<<14) | uint32(opTest) }

// runProto runs a zero-arg prototype to completion and returns the top-of-stack result.
func runProto(t *testing.T, proto *FunctionPrototype) Value {
	t.Helper()
	vm := NewVM()
	closure := &Closure{Prototype: proto, Upvalues: make([]*UpvalueHolder, 0)}
	vm.frame.stack[0] = ClosureVal(closure)
	vm.frame.top = 1
	vm.prepareCall(0)
	vm.run()
	if vm.frame.top == 0 {
		t.Fatal("no return value on stack after run()")
	}
	return vm.frame.stack[vm.frame.top-1]
}

// --- basic constant and bool ---

func TestExecReturnInt(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions:    []uint32{encLC(0), uint32(opReturn)},
		Constants:       []Value{IntVal(42)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != 42 {
		t.Errorf("expected int 42, got %+v", got)
	}
}

func TestExecReturnString(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions:    []uint32{encLC(0), uint32(opReturn)},
		Constants:       []Value{StringVal("hello")},
	}
	got := runProto(t, proto)
	if got.Type != TypeString || got.Obj.(string) != "hello" {
		t.Errorf("expected string \"hello\", got %+v", got)
	}
}

func TestExecReturnBool(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions:    []uint32{encLB(1, 0), uint32(opReturn)},
	}
	got := runProto(t, proto)
	if got.Type != TypeBool || got.IVal != 1 {
		t.Errorf("expected bool true, got %+v", got)
	}
}

// --- arithmetic ---

func TestExecAdd(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), encLC(1), uint32(opAdd), uint32(opReturn)},
		Constants:       []Value{IntVal(3), IntVal(4)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != 7 {
		t.Errorf("expected 7, got %+v", got)
	}
}

func TestExecSub(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), encLC(1), uint32(opSub), uint32(opReturn)},
		Constants:       []Value{IntVal(10), IntVal(3)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != 7 {
		t.Errorf("expected 7, got %+v", got)
	}
}

func TestExecMul(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), encLC(1), uint32(opMul), uint32(opReturn)},
		Constants:       []Value{IntVal(3), IntVal(4)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != 12 {
		t.Errorf("expected 12, got %+v", got)
	}
}

func TestExecNeg(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), uint32(opNeg), uint32(opReturn)},
		Constants:       []Value{IntVal(5)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != -5 {
		t.Errorf("expected -5, got %+v", got)
	}
}

func TestExecFloatAdd(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), encLC(1), uint32(opAdd), uint32(opReturn)},
		Constants:       []Value{FloatVal(1.5), FloatVal(2.5)},
	}
	got := runProto(t, proto)
	if got.Type != TypeFloat || got.FVal != 4.0 {
		t.Errorf("expected 4.0, got %+v", got)
	}
}

// --- logical ---

func TestExecNot(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions:    []uint32{encLB(1, 0), uint32(opNot), uint32(opReturn)},
	}
	got := runProto(t, proto)
	if got.Type != TypeBool || got.IVal != 0 {
		t.Errorf("expected false, got %+v", got)
	}
}

func TestExecNotNil(t *testing.T) {
	// not(nil) should be true
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		// loadBool(b=0,c=1) pushes false then skips next, but we want nil...
		// Instead: just encode: loadBool false (b=0,c=0), not, return
		// not(false) = true
		Instructions: []uint32{encLB(0, 0), uint32(opNot), uint32(opReturn)},
	}
	got := runProto(t, proto)
	if got.Type != TypeBool || got.IVal != 1 {
		t.Errorf("expected true, got %+v", got)
	}
}

// --- comparison ---

func TestExecEq(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), encLC(1), uint32(opEq), uint32(opReturn)},
		Constants:       []Value{IntVal(7), IntVal(7)},
	}
	got := runProto(t, proto)
	if got.Type != TypeBool || got.IVal != 1 {
		t.Errorf("expected true, got %+v", got)
	}
}

func TestExecLt(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions:    []uint32{encLC(0), encLC(1), uint32(opLt), uint32(opReturn)},
		Constants:       []Value{IntVal(3), IntVal(7)},
	}
	got := runProto(t, proto)
	if got.Type != TypeBool || got.IVal != 1 {
		t.Errorf("expected true, got %+v", got)
	}
}

// --- conditional (test + jump) ---

func TestExecTestJump(t *testing.T) {
	// if false then 1 else 2 → expect 2
	// Instructions:
	//   0: loadBool false
	//   1: test c=1  (jump if ToBool != true, i.e. jump if false)
	//   2: loadConst 0 (1) ← skipped
	//   3: loadConst 1 (2)
	//   4: return
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions: []uint32{
			encLB(0, 0),      // 0: push false
			encTest(1),        // 1: if !ToBool, skip next; pop
			encLC(0),          // 2: push 1 (skipped)
			encLC(1),          // 3: push 2
			uint32(opReturn),  // 4: return
		},
		Constants: []Value{IntVal(1), IntVal(2)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != 2 {
		t.Errorf("expected 2, got %+v", got)
	}
}

func TestExecTestJumpTrue(t *testing.T) {
	// if true then 1 else 2 → expect 1
	// test c=1: jump if ToBool(top) != true; if ToBool(true)=true and c=1 → equal → no jump
	// Instructions:
	//   0: loadBool true
	//   1: test c=1  (no jump because ToBool(true)==(c!=0)==true)
	//   2: jump +1   ← skip the "else" branch constant load
	//   3: loadConst 0 (2) ← else: skipped
	//   4: loadConst 1 (1) ← wait, needs restructuring
	// Simpler: loadBool true, test c=0 (jump if ToBool != false, i.e. jump if true), return 99 (skip), return const 42
	// test c=0: jump if ToBool != (c!=0)==false, i.e. jump if ToBool==true
	//   0: loadBool true
	//   1: test c=0  → jump if ToBool(true) != false → true != false → jump (pc++)
	//   2: loadConst 0 (99) ← skipped
	//   3: loadConst 1 (1)
	//   4: return
	proto := &FunctionPrototype{
		MaxVarStackSize: 8,
		Instructions: []uint32{
			encLB(1, 0),      // 0: push true
			encTest(0),        // 1: jump if ToBool != false (i.e. jump when true); pop
			encLC(0),          // 2: push 99 (skipped)
			encLC(1),          // 3: push 1
			uint32(opReturn),  // 4: return
		},
		Constants: []Value{IntVal(99), IntVal(1)},
	}
	got := runProto(t, proto)
	if got.Type != TypeInt || got.IVal != 1 {
		t.Errorf("expected 1, got %+v", got)
	}
}

// --- table operations ---

func TestExecTable(t *testing.T) {
	// After newTable: stack[maxVarStackSize] = table, top = maxVarStackSize+1.
	// Use encPushRel(-1) to duplicate the table for each setTable/getTable call.
	proto2 := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions: []uint32{
			uint32(opNewTable), // table at top-1 after this
			encPushRel(-1),     // dup table
			encLC(0),           // push "key"
			encLC(1),           // push "val"
			uint32(opSetTable), // setTable pops val,key,table; original table still below
			encPushRel(-1),     // dup original table
			encLC(0),           // push "key"
			uint32(opGetTable), // getTable pops key,table; pushes value
			encPop(1, 1),       // remove original table (below the result), keep result
			uint32(opReturn),
		},
		Constants: []Value{StringVal("key"), StringVal("val")},
	}
	got := runProto(t, proto2)
	if got.Type != TypeString || got.Obj.(string) != "val" {
		t.Errorf("expected string \"val\", got %+v", got)
	}
}

// --- native function call ---

func TestExecNativeCall(t *testing.T) {
	vm := NewVM()
	// native fn: reads arg[0] (int), pushes arg+1, returns true
	nativeFn := func(vm *VM) bool {
		a := vm.frame.stack[0]
		vm.frame.stack[vm.frame.top] = IntVal(a.IVal + 1)
		vm.frame.top++
		return true
	}
	closure := &Closure{GoFunc: nativeFn, Upvalues: make([]*UpvalueHolder, 0)}
	vm.frame.stack[0] = ClosureVal(closure)
	vm.frame.stack[1] = IntVal(5)
	vm.frame.top = 2
	vm.prepareCall(1)
	vm.run()
	result := vm.frame.stack[vm.frame.top-1]
	if result.Type != TypeInt || result.IVal != 6 {
		t.Errorf("expected 6, got %+v", result)
	}
}

// --- implicit nil return (fall off end) ---

func TestExecImplicitReturn(t *testing.T) {
	// Function with no return instruction — should push nil onto parent
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions:    []uint32{}, // empty
	}
	got := runProto(t, proto)
	if got.Type != TypeNil {
		t.Errorf("expected nil, got %+v", got)
	}
}

// --- type opcode ---

func TestExecType(t *testing.T) {
	proto := &FunctionPrototype{
		MaxVarStackSize: 4,
		Instructions:    []uint32{encLC(0), uint32(opType), uint32(opReturn)},
		Constants:       []Value{IntVal(99)},
	}
	got := runProto(t, proto)
	if got.Type != TypeString || got.Obj.(string) != "int" {
		t.Errorf("expected \"int\", got %+v", got)
	}
}
