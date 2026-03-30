package slang_vm

func buildBitwiseModule() *SlangTable {
	t := NewSlangTable()
	setFn := func(name string, fn GoFunction) {
		t.Set(StringVal(name), ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}))
	}
	setFn("band", bitwiseBand)
	setFn("bor", bitwiseBor)
	setFn("bxor", bitwiseBxor)
	setFn("lshift", bitwiseLshift)
	setFn("rshift", bitwiseRshift)
	return t
}

func bitwiseBand(vm *VM) bool {
	a := vm.GetIntArg(0)
	b := vm.GetIntArg(1)
	vm.Push(IntVal(a & b))
	return true
}

func bitwiseBor(vm *VM) bool {
	a := vm.GetIntArg(0)
	b := vm.GetIntArg(1)
	vm.Push(IntVal(a | b))
	return true
}

func bitwiseBxor(vm *VM) bool {
	a := vm.GetIntArg(0)
	b := vm.GetIntArg(1)
	vm.Push(IntVal(a ^ b))
	return true
}

func bitwiseLshift(vm *VM) bool {
	a := vm.GetIntArg(0)
	n := vm.GetIntArg(1)
	vm.Push(IntVal(a << uint(n)))
	return true
}

func bitwiseRshift(vm *VM) bool {
	a := vm.GetIntArg(0)
	n := vm.GetIntArg(1)
	vm.Push(IntVal(a >> uint(n)))
	return true
}
