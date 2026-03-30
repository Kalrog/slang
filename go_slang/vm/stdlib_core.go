package slang_vm

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// valueToString converts a Value to its string representation.
func valueToString(v Value) string {
	switch v.Type {
	case TypeNil:
		return "null"
	case TypeBool:
		if v.IVal != 0 {
			return "true"
		}
		return "false"
	case TypeInt:
		return strconv.FormatInt(v.IVal, 10)
	case TypeFloat:
		return strconv.FormatFloat(v.FVal, 'g', -1, 64)
	case TypeString:
		return v.Obj.(string)
	case TypeTable:
		return fmt.Sprintf("table: %p", v.Obj.(*SlangTable))
	case TypeClosure:
		return fmt.Sprintf("function: %p", v.Obj.(*Closure))
	case TypeUserdata:
		return fmt.Sprintf("userdata: %p", v.Obj.(*Userdata))
	default:
		return "?"
	}
}

func corePrint(vm *VM) bool {
	n := vm.GetTop()
	parts := make([]string, n)
	for i := 0; i < n; i++ {
		parts[i] = valueToString(vm.stackArg(i))
	}
	fmt.Fprintln(os.Stdout, strings.Join(parts, "\t"))
	return false
}

func coreReadLine(vm *VM) bool {
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil && line == "" {
		vm.Push(NilVal())
		return true
	}
	vm.Push(StringVal(strings.TrimRight(line, "\n\r")))
	return true
}

func coreOpen(vm *VM) bool {
	path := vm.GetStringArg(0)
	modeStr := "r"
	if vm.GetTop() > 1 {
		modeStr = vm.GetStringArg(1)
	}
	var flag int
	switch modeStr {
	case "r":
		flag = os.O_RDONLY
	case "w":
		flag = os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	case "a":
		flag = os.O_WRONLY | os.O_CREATE | os.O_APPEND
	case "rw", "r+":
		flag = os.O_RDWR
	default:
		flag = os.O_RDONLY
	}
	f, err := os.OpenFile(path, flag, 0644)
	if err != nil {
		panic(&SlangException{Message: err.Error()})
	}
	reader := bufio.NewReader(f)
	meta := NewSlangTable()
	meta.Set(StringVal("read"), ClosureVal(&Closure{
		GoFunc: func(vm *VM) bool {
			line, rerr := reader.ReadString('\n')
			if rerr != nil && line == "" {
				vm.Push(NilVal())
				return true
			}
			vm.Push(StringVal(strings.TrimRight(line, "\n\r")))
			return true
		},
		Upvalues: make([]*UpvalueHolder, 0),
	}))
	meta.Set(StringVal("write"), ClosureVal(&Closure{
		GoFunc: func(vm *VM) bool {
			s := vm.GetStringArg(1) // arg0 = self (file userdata)
			f.WriteString(s)        //nolint:errcheck
			return false
		},
		Upvalues: make([]*UpvalueHolder, 0),
	}))
	meta.Set(StringVal("close"), ClosureVal(&Closure{
		GoFunc: func(vm *VM) bool {
			f.Close() //nolint:errcheck
			return false
		},
		Upvalues: make([]*UpvalueHolder, 0),
	}))
	ud := &Userdata{Value: f, MetaTable: meta}
	vm.Push(UserdataVal(ud))
	return true
}

func coreAssert(vm *VM) bool {
	v := vm.stackArg(0)
	if !v.ToBool() {
		msg := "assertion failed"
		if vm.GetTop() > 1 {
			msg = valueToString(vm.stackArg(1))
		}
		panic(&SlangException{Message: msg})
	}
	return false
}

func coreAppend(vm *VM) bool {
	t := vm.GetTableArg(0)
	v := vm.stackArg(1)
	t.Append(v)
	return false
}

func coreRemove(vm *VM) bool {
	t := vm.GetTableArg(0)
	key := vm.stackArg(1)
	old := t.Get(key)
	t.Set(key, NilVal())
	vm.Push(old)
	return true
}

func coreKeys(vm *VM) bool {
	t := vm.GetTableArg(0)
	entries := t.AllEntries()
	idx := 0
	iter := &Closure{
		GoFunc: func(vm *VM) bool {
			if idx >= len(entries) {
				vm.Push(NilVal())
				return true
			}
			vm.Push(entries[idx][0])
			idx++
			return true
		},
		Upvalues: make([]*UpvalueHolder, 0),
	}
	vm.Push(ClosureVal(iter))
	return true
}

func coreValues(vm *VM) bool {
	t := vm.GetTableArg(0)
	entries := t.AllEntries()
	idx := 0
	iter := &Closure{
		GoFunc: func(vm *VM) bool {
			if idx >= len(entries) {
				vm.Push(NilVal())
				return true
			}
			vm.Push(entries[idx][1])
			idx++
			return true
		},
		Upvalues: make([]*UpvalueHolder, 0),
	}
	vm.Push(ClosureVal(iter))
	return true
}

func coreEntries(vm *VM) bool {
	t := vm.GetTableArg(0)
	entries := t.AllEntries()
	idx := 0
	iter := &Closure{
		GoFunc: func(vm *VM) bool {
			if idx >= len(entries) {
				vm.Push(NilVal())
				return true
			}
			pair := NewSlangTable()
			pair.Append(entries[idx][0])
			pair.Append(entries[idx][1])
			idx++
			vm.Push(TableVal(pair))
			return true
		},
		Upvalues: make([]*UpvalueHolder, 0),
	}
	vm.Push(ClosureVal(iter))
	return true
}

func coreConcat(vm *VM) bool {
	n := vm.GetTop()
	if n == 0 {
		vm.Push(StringVal(""))
		return true
	}
	first := vm.stackArg(0)
	if first.Type == TypeString {
		var sb strings.Builder
		for i := 0; i < n; i++ {
			sb.WriteString(valueToString(vm.stackArg(i)))
		}
		vm.Push(StringVal(sb.String()))
		return true
	}
	// Table merge: flatten array parts, merge hash parts.
	result := NewSlangTable()
	for i := 0; i < n; i++ {
		arg := vm.stackArg(i)
		if arg.Type != TypeTable {
			continue
		}
		t := arg.Obj.(*SlangTable)
		for _, e := range t.AllEntries() {
			if e[0].Type == TypeInt {
				result.Append(e[1])
			} else {
				result.Set(e[0], e[1])
			}
		}
	}
	vm.Push(TableVal(result))
	return true
}

func corePcall(vm *VM) bool {
	nargs := vm.GetTop() - 1 // closure is arg 0
	err := vm.PCall(nargs)
	if err != nil {
		// PCall pushed the error table onto the current frame.
		return true
	}
	// Success: fn's return value is on the frame but we discard it.
	return false
}

func coreError(vm *VM) bool {
	msg := "error"
	if vm.GetTop() > 0 {
		msg = valueToString(vm.stackArg(0))
	}
	panic(&SlangException{Message: msg})
}

func coreLen(vm *VM) bool {
	v := vm.stackArg(0)
	switch v.Type {
	case TypeString:
		vm.Push(IntVal(int64(len(v.Obj.(string)))))
	case TypeTable:
		vm.Push(IntVal(int64(v.Obj.(*SlangTable).Length())))
	default:
		panic(&SlangException{Message: "len: expected string or table, got " + v.TypeName()})
	}
	return true
}

func coreType(vm *VM) bool {
	vm.Push(StringVal(vm.stackArg(0).TypeName()))
	return true
}

func coreSetRaw(vm *VM) bool {
	t := vm.GetTableArg(0)
	key := vm.stackArg(1)
	val := vm.stackArg(2)
	t.Set(key, val)
	return false
}

func coreGetRaw(vm *VM) bool {
	t := vm.GetTableArg(0)
	key := vm.stackArg(1)
	vm.Push(t.Get(key))
	return true
}

func coreToInt(vm *VM) bool {
	v := vm.stackArg(0)
	switch v.Type {
	case TypeInt:
		vm.Push(v)
	case TypeFloat:
		vm.Push(IntVal(int64(v.FVal)))
	case TypeString:
		n, err := strconv.ParseInt(v.Obj.(string), 10, 64)
		if err != nil {
			panic(&SlangException{Message: "to_int: invalid integer string: " + v.Obj.(string)})
		}
		vm.Push(IntVal(n))
	default:
		panic(&SlangException{Message: "to_int: cannot convert " + v.TypeName()})
	}
	return true
}

func coreString(vm *VM) bool {
	vm.Push(StringVal(valueToString(vm.stackArg(0))))
	return true
}

func coreArgs(vm *VM) bool {
	t := NewSlangTable()
	for _, arg := range os.Args {
		t.Append(StringVal(arg))
	}
	vm.Push(TableVal(t))
	return true
}

func coreCompileStub(vm *VM) bool {
	panic("compile/load: not implemented; will be implemented in slang")
}

func registerCoreLib(vm *VM) {
	vm.RegisterGoFunction("print", corePrint)
	vm.RegisterGoFunction("readLine", coreReadLine)
	vm.RegisterGoFunction("open", coreOpen)
	vm.RegisterGoFunction("assert", coreAssert)
	vm.RegisterGoFunction("append", coreAppend)
	vm.RegisterGoFunction("remove", coreRemove)
	vm.RegisterGoFunction("keys", coreKeys)
	vm.RegisterGoFunction("values", coreValues)
	vm.RegisterGoFunction("entries", coreEntries)
	vm.RegisterGoFunction("concat", coreConcat)
	vm.RegisterGoFunction("pcall", corePcall)
	vm.RegisterGoFunction("error", coreError)
	vm.RegisterGoFunction("len", coreLen)
	vm.RegisterGoFunction("type", coreType)
	vm.RegisterGoFunction("set_raw", coreSetRaw)
	vm.RegisterGoFunction("get_raw", coreGetRaw)
	vm.RegisterGoFunction("to_int", coreToInt)
	vm.RegisterGoFunction("string", coreString)
	vm.RegisterGoFunction("args", coreArgs)
	vm.RegisterGoFunction("compile", coreCompileStub)
	vm.RegisterGoFunction("load", coreCompileStub)
}
