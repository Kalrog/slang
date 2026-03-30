package slang_vm

import "fmt"

// LoadAndRun loads a prototype as the root function, wires _ENV to globals,
// and executes it to completion. Returns any *SlangException that was thrown.
func (vm *VM) LoadAndRun(proto *FunctionPrototype) (err error) {
	closure := &Closure{
		Prototype: proto,
		Upvalues:  make([]*UpvalueHolder, len(proto.Upvalues)),
	}
	for i, uv := range proto.Upvalues {
		if uv.Name == "_ENV" {
			closure.Upvalues[i] = &UpvalueHolder{value: TableVal(vm.globals)}
		} else {
			closure.Upvalues[i] = &UpvalueHolder{}
		}
	}

	frame := vm.frame
	frame.stack[frame.top] = ClosureVal(closure)
	frame.top++

	return vm.PCall(0)
}

// Call pops nargs args and a closure from the stack and runs to completion.
// Panics propagate to the caller; use PCall for error recovery.
func (vm *VM) Call(nargs int) {
	vm.prepareCall(nargs)
	vm.run()
}

// PCall is like Call but recovers from panics (including *SlangException).
// On error it restores the frame, pushes a {err: {message}} table, and
// returns the wrapped error. Returns nil on success.
func (vm *VM) PCall(nargs int) (err error) {
	savedFrame := vm.frame
	defer func() {
		if r := recover(); r != nil {
			// Restore frame to the state before the call.
			vm.frame = savedFrame

			var exc *SlangException
			switch v := r.(type) {
			case *SlangException:
				exc = v
			case error:
				exc = &SlangException{Message: v.Error()}
			default:
				exc = &SlangException{Message: fmt.Sprintf("%v", v)}
			}

			// Push {err: {message, location}} onto restored frame.
			errInner := NewSlangTable()
			errInner.Set(StringVal("message"), StringVal(exc.Message))
			if exc.Location != nil {
				locTable := NewSlangTable()
				locTable.Set(StringVal("origin"), StringVal(exc.Location.Origin))
				locTable.Set(StringVal("line"), IntVal(int64(exc.Location.Line)))
				locTable.Set(StringVal("col"), IntVal(int64(exc.Location.Col)))
				errInner.Set(StringVal("location"), TableVal(locTable))
			}
			errOuter := NewSlangTable()
			errOuter.Set(StringVal("err"), TableVal(errInner))
			vm.frame.stack[vm.frame.top] = TableVal(errOuter)
			vm.frame.top++

			err = exc
		}
	}()

	vm.Call(nargs)
	return nil
}

// RegisterGoFunction registers a Go native function under name in globals.
func (vm *VM) RegisterGoFunction(name string, fn GoFunction) {
	closure := &Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}
	vm.globals.Set(StringVal(name), ClosureVal(closure))
}

// Globals returns the VM's global table.
func (vm *VM) Globals() *SlangTable { return vm.globals }

// GetTop returns the number of values on the current frame's stack.
func (vm *VM) GetTop() int { return vm.frame.top }

// Push pushes a value onto the current frame's stack.
func (vm *VM) Push(v Value) {
	vm.frame.stack[vm.frame.top] = v
	vm.frame.top++
}

// Pop removes and returns the top value from the current frame's stack.
func (vm *VM) Pop() Value {
	vm.frame.top--
	return vm.frame.stack[vm.frame.top]
}

// stackArg returns the value at position n (0-based) in the current frame.
func (vm *VM) stackArg(n int) Value { return vm.frame.stack[n] }

// GetIntArg returns arg n as int64 (panics if wrong type).
func (vm *VM) GetIntArg(n int) int64 {
	v := vm.stackArg(n)
	if v.Type != TypeInt {
		panic(fmt.Sprintf("GetIntArg(%d): expected int, got %s", n, v.TypeName()))
	}
	return v.IVal
}

// GetFloatArg returns arg n as float64. Accepts both int and float.
func (vm *VM) GetFloatArg(n int) float64 {
	v := vm.stackArg(n)
	switch v.Type {
	case TypeFloat:
		return v.FVal
	case TypeInt:
		return float64(v.IVal)
	}
	panic(fmt.Sprintf("GetFloatArg(%d): expected number, got %s", n, v.TypeName()))
}

// GetStringArg returns arg n as string (panics if wrong type).
func (vm *VM) GetStringArg(n int) string {
	v := vm.stackArg(n)
	if v.Type != TypeString {
		panic(fmt.Sprintf("GetStringArg(%d): expected string, got %s", n, v.TypeName()))
	}
	return v.Obj.(string)
}

// GetBoolArg returns arg n as bool (panics if wrong type).
func (vm *VM) GetBoolArg(n int) bool {
	v := vm.stackArg(n)
	if v.Type != TypeBool {
		panic(fmt.Sprintf("GetBoolArg(%d): expected bool, got %s", n, v.TypeName()))
	}
	return v.IVal != 0
}

// GetTableArg returns arg n as *SlangTable (panics if wrong type).
func (vm *VM) GetTableArg(n int) *SlangTable {
	v := vm.stackArg(n)
	if v.Type != TypeTable {
		panic(fmt.Sprintf("GetTableArg(%d): expected table, got %s", n, v.TypeName()))
	}
	return v.Obj.(*SlangTable)
}

// GetClosureArg returns arg n as *Closure (panics if wrong type).
func (vm *VM) GetClosureArg(n int) *Closure {
	v := vm.stackArg(n)
	if v.Type != TypeClosure {
		panic(fmt.Sprintf("GetClosureArg(%d): expected closure, got %s", n, v.TypeName()))
	}
	return v.Obj.(*Closure)
}

// GetUserdataArg returns arg n as *Userdata (panics if wrong type).
func (vm *VM) GetUserdataArg(n int) *Userdata {
	v := vm.stackArg(n)
	if v.Type != TypeUserdata {
		panic(fmt.Sprintf("GetUserdataArg(%d): expected userdata, got %s", n, v.TypeName()))
	}
	return v.Obj.(*Userdata)
}

// PushNil pushes a nil value.
func (vm *VM) PushNil() { vm.Push(NilVal()) }

// PushBool pushes a bool value.
func (vm *VM) PushBool(b bool) { vm.Push(BoolVal(b)) }

// PushInt pushes an int value.
func (vm *VM) PushInt(i int64) { vm.Push(IntVal(i)) }

// PushFloat pushes a float value.
func (vm *VM) PushFloat(f float64) { vm.Push(FloatVal(f)) }

// PushString pushes a string value.
func (vm *VM) PushString(s string) { vm.Push(StringVal(s)) }

// PushTable pushes a table value.
func (vm *VM) PushTable(t *SlangTable) { vm.Push(TableVal(t)) }

// Invoke calls a slang closure with the given args re-entrantly and returns its result.
// Safe to call while the VM is already executing (each Invoke gets its own frame).
func (vm *VM) Invoke(closure Value, args []Value) (result Value, err error) {
	if closure.Type != TypeClosure {
		return NilVal(), &SlangException{Message: "Invoke: expected closure"}
	}
	savedTop := vm.frame.top
	vm.Push(closure)
	for _, a := range args {
		vm.Push(a)
	}
	err = vm.PCall(len(args))
	if err != nil {
		vm.frame.top = savedTop
		return NilVal(), err
	}
	if vm.frame.top > savedTop {
		result = vm.frame.stack[savedTop]
		vm.frame.top = savedTop
	}
	return result, nil
}

// wrapPrototype creates a Closure for proto, wiring any _ENV upvalue to vm.globals.
func (vm *VM) wrapPrototype(proto *FunctionPrototype) *Closure {
	cl := &Closure{
		Prototype: proto,
		Upvalues:  make([]*UpvalueHolder, len(proto.Upvalues)),
	}
	for i, uv := range proto.Upvalues {
		if uv.Name == "_ENV" {
			cl.Upvalues[i] = &UpvalueHolder{value: TableVal(vm.globals)}
		} else {
			cl.Upvalues[i] = &UpvalueHolder{}
		}
	}
	return cl
}
