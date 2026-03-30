package slang_vm

import "testing"

// makeIntTable builds a SlangTable from a slice of int64 values.
func makeIntTable(vals ...int64) *SlangTable {
	t := NewSlangTable()
	for _, v := range vals {
		t.Append(IntVal(v))
	}
	return t
}

// tableToInts extracts the array part of a table as []int64.
func tableToInts(t *SlangTable) []int64 {
	out := make([]int64, t.Length())
	for i := range out {
		out[i] = t.Get(IntVal(int64(i))).IVal
	}
	return out
}

// registerGoFn is a helper that creates a GoFunction closure.
func makeGoClosure(fn GoFunction) Value {
	return ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)})
}

func TestTableModule(t *testing.T) {
	m := buildTableModule()

	t.Run("contains_found", func(t *testing.T) {
		tbl := makeIntTable(1, 2, 3)
		got := callModuleFn(t, m, "contains", TableVal(tbl), IntVal(2))
		if !got.ToBool() {
			t.Error("contains(2) should be true")
		}
	})

	t.Run("contains_not_found", func(t *testing.T) {
		tbl := makeIntTable(1, 2, 3)
		got := callModuleFn(t, m, "contains", TableVal(tbl), IntVal(5))
		if got.ToBool() {
			t.Error("contains(5) should be false")
		}
	})

	t.Run("map_doubles", func(t *testing.T) {
		// f(x) = x * 2 implemented as a GoFunction
		double := makeGoClosure(func(vm *VM) bool {
			vm.Push(IntVal(vm.stackArg(0).IVal * 2))
			return true
		})
		tbl := makeIntTable(1, 2, 3)
		vm := NewVM()
		vm.RegisterGoFunction("__test_fn", func(v *VM) bool {
			_ = double
			return false
		})
		// Call table.map directly
		mapFn := m.Get(StringVal("map"))
		f := vm.frame
		f.stack[0] = mapFn
		f.stack[1] = TableVal(tbl)
		f.stack[2] = double
		f.top = 3
		vm.prepareCall(2)
		vm.run()
		result := vm.frame.stack[vm.frame.top-1]
		if result.Type != TypeTable {
			t.Fatalf("map returned %s, want table", result.TypeName())
		}
		got := tableToInts(result.Obj.(*SlangTable))
		want := []int64{2, 4, 6}
		for i, v := range want {
			if got[i] != v {
				t.Errorf("map result[%d] = %d, want %d", i, got[i], v)
			}
		}
	})

	t.Run("filter_evens", func(t *testing.T) {
		isEven := makeGoClosure(func(vm *VM) bool {
			vm.Push(BoolVal(vm.stackArg(0).IVal%2 == 0))
			return true
		})
		tbl := makeIntTable(1, 2, 3, 4, 5)
		filterFn := m.Get(StringVal("filter"))
		vm := NewVM()
		f := vm.frame
		f.stack[0] = filterFn
		f.stack[1] = TableVal(tbl)
		f.stack[2] = isEven
		f.top = 3
		vm.prepareCall(2)
		vm.run()
		result := vm.frame.stack[vm.frame.top-1].Obj.(*SlangTable)
		got := tableToInts(result)
		want := []int64{2, 4}
		if len(got) != len(want) {
			t.Fatalf("filter len = %d, want %d", len(got), len(want))
		}
		for i := range want {
			if got[i] != want[i] {
				t.Errorf("filter[%d] = %d, want %d", i, got[i], want[i])
			}
		}
	})

	t.Run("fold_sum", func(t *testing.T) {
		add := makeGoClosure(func(vm *VM) bool {
			vm.Push(IntVal(vm.stackArg(0).IVal + vm.stackArg(1).IVal))
			return true
		})
		tbl := makeIntTable(1, 2, 3, 4)
		foldFn := m.Get(StringVal("fold"))
		vm := NewVM()
		f := vm.frame
		f.stack[0] = foldFn
		f.stack[1] = TableVal(tbl)
		f.stack[2] = IntVal(0) // init
		f.stack[3] = add
		f.top = 4
		vm.prepareCall(3)
		vm.run()
		got := vm.frame.stack[vm.frame.top-1].IVal
		if got != 10 {
			t.Errorf("fold sum = %d, want 10", got)
		}
	})

	t.Run("dequeue", func(t *testing.T) {
		tbl := makeIntTable(10, 20, 30)
		got := callModuleFn(t, m, "dequeue", TableVal(tbl))
		if got.IVal != 10 {
			t.Errorf("dequeue returned %d, want 10", got.IVal)
		}
		if tbl.Length() != 2 {
			t.Errorf("after dequeue len = %d, want 2", tbl.Length())
		}
		if tbl.Get(IntVal(0)).IVal != 20 {
			t.Errorf("after dequeue tbl[0] = %d, want 20", tbl.Get(IntVal(0)).IVal)
		}
	})

	t.Run("dequeue_empty", func(t *testing.T) {
		tbl := NewSlangTable()
		got := callModuleFn(t, m, "dequeue", TableVal(tbl))
		if got.Type != TypeNil {
			t.Errorf("dequeue empty = %s, want nil", got.TypeName())
		}
	})
}
