package slang_vm

import "strings"

func buildStringModule() *SlangTable {
	t := NewSlangTable()
	set := func(name string, fn GoFunction) {
		t.Set(StringVal(name), ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}))
	}
	set("join", stringJoin)
	set("substring", stringSubstring)
	return t
}

// stringJoin(t, sep=" ") joins array elements of t with sep.
func stringJoin(vm *VM) bool {
	t := vm.GetTableArg(0)
	sep := " "
	if vm.GetTop() > 1 {
		sep = vm.GetStringArg(1)
	}
	n := t.Length()
	parts := make([]string, n)
	for i := 0; i < n; i++ {
		parts[i] = valueToString(t.Get(IntVal(int64(i))))
	}
	vm.Push(StringVal(strings.Join(parts, sep)))
	return true
}

// stringSubstring(str, start=0, end=len) returns a rune-safe slice.
func stringSubstring(vm *VM) bool {
	s := vm.GetStringArg(0)
	runes := []rune(s)
	n := len(runes)
	start, end := 0, n
	if vm.GetTop() > 1 {
		start = int(vm.GetIntArg(1))
		if start < 0 {
			start = 0
		}
		if start > n {
			start = n
		}
	}
	if vm.GetTop() > 2 {
		end = int(vm.GetIntArg(2))
		if end < start {
			end = start
		}
		if end > n {
			end = n
		}
	}
	vm.Push(StringVal(string(runes[start:end])))
	return true
}
