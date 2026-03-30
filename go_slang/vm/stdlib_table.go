package slang_vm

func buildTableModule() *SlangTable {
	t := NewSlangTable()
	set := func(name string, fn GoFunction) {
		t.Set(StringVal(name), ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}))
	}
	set("contains", tableContains)
	set("map", tableMap)
	set("filter", tableFilter)
	set("fold", tableFold)
	set("dequeue", tableDequeue)
	return t
}

// tableContains(t, value) performs a linear scan over the array part.
func tableContains(vm *VM) bool {
	t := vm.GetTableArg(0)
	val := vm.stackArg(1)
	for i := 0; i < t.Length(); i++ {
		if valEqual(t.Get(IntVal(int64(i))), val) {
			vm.Push(BoolVal(true))
			return true
		}
	}
	vm.Push(BoolVal(false))
	return true
}

// tableMap(t, f) applies f to each array element and returns a new table.
func tableMap(vm *VM) bool {
	t := vm.GetTableArg(0)
	fn := vm.GetClosureArg(1)
	result := NewSlangTable()
	n := t.Length()
	for i := 0; i < n; i++ {
		v := t.Get(IntVal(int64(i)))
		vm.Push(ClosureVal(fn))
		vm.Push(v)
		vm.Call(1)
		result.Append(vm.Pop())
	}
	vm.Push(TableVal(result))
	return true
}

// tableFilter(t, f) returns a new table with elements for which f returns truthy.
func tableFilter(vm *VM) bool {
	t := vm.GetTableArg(0)
	fn := vm.GetClosureArg(1)
	result := NewSlangTable()
	n := t.Length()
	for i := 0; i < n; i++ {
		v := t.Get(IntVal(int64(i)))
		vm.Push(ClosureVal(fn))
		vm.Push(v)
		vm.Call(1)
		if vm.Pop().ToBool() {
			result.Append(v)
		}
	}
	vm.Push(TableVal(result))
	return true
}

// tableFold(t, init, f) accumulates acc = f(acc, v) over array elements.
func tableFold(vm *VM) bool {
	t := vm.GetTableArg(0)
	acc := vm.stackArg(1)
	fn := vm.GetClosureArg(2)
	n := t.Length()
	for i := 0; i < n; i++ {
		v := t.Get(IntVal(int64(i)))
		vm.Push(ClosureVal(fn))
		vm.Push(acc)
		vm.Push(v)
		vm.Call(2)
		acc = vm.Pop()
	}
	vm.Push(acc)
	return true
}

// tableDequeue(t) removes and returns the first element, shifting the rest down.
func tableDequeue(vm *VM) bool {
	t := vm.GetTableArg(0)
	vm.Push(t.Dequeue())
	return true
}
