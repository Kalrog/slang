package slang_vm

func buildVMModule() *SlangTable {
	t := NewSlangTable()
	set := func(name string, fn GoFunction) {
		t.Set(StringVal(name), ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}))
	}
	set("setUpvalue", vmSetUpvalue)
	set("getUpvalue", vmGetUpvalue)
	set("upvalueNames", vmUpvalueNames)
	return t
}

// vmSetUpvalue(closure, name, value) sets a named upvalue on a slang closure.
func vmSetUpvalue(vm *VM) bool {
	cl := vm.GetClosureArg(0)
	name := vm.GetStringArg(1)
	val := vm.stackArg(2)
	if cl.Prototype == nil {
		panic(&SlangException{Message: "setUpvalue: not a slang closure"})
	}
	for i, uv := range cl.Prototype.Upvalues {
		if uv.Name == name {
			cl.Upvalues[i].Set(val)
			return false
		}
	}
	panic(&SlangException{Message: "setUpvalue: upvalue not found: " + name})
}

// vmGetUpvalue(closure, name) returns the value of a named upvalue, or nil.
func vmGetUpvalue(vm *VM) bool {
	cl := vm.GetClosureArg(0)
	name := vm.GetStringArg(1)
	if cl.Prototype != nil {
		for i, uv := range cl.Prototype.Upvalues {
			if uv.Name == name {
				vm.Push(cl.Upvalues[i].Get())
				return true
			}
		}
	}
	vm.Push(NilVal())
	return true
}

// vmUpvalueNames(closure) returns a table of upvalue name strings.
func vmUpvalueNames(vm *VM) bool {
	cl := vm.GetClosureArg(0)
	result := NewSlangTable()
	if cl.Prototype != nil {
		for _, uv := range cl.Prototype.Upvalues {
			result.Append(StringVal(uv.Name))
		}
	}
	vm.Push(TableVal(result))
	return true
}
