package slang_vm

import (
	"math"
	"testing"
)

// callModuleFn calls a function from a module table with the given args.
func callModuleFn(t *testing.T, tbl *SlangTable, name string, args ...Value) Value {
	t.Helper()
	fn := tbl.Get(StringVal(name))
	if fn.Type != TypeClosure {
		t.Fatalf("callModuleFn: %q not found in module", name)
	}
	vm := NewVM()
	f := vm.frame
	f.stack[0] = fn
	f.top = 1
	for i, a := range args {
		f.stack[f.top] = a
		f.top++
		_ = i
	}
	vm.prepareCall(len(args))
	vm.run()
	if vm.frame.top == 0 {
		t.Fatalf("callModuleFn: no return value for %q", name)
	}
	return vm.frame.stack[vm.frame.top-1]
}

func approxEq(a, b float64) bool { return math.Abs(a-b) < 1e-9 }

func TestMathModule(t *testing.T) {
	m := buildMathModule()

	// constants
	pi := m.Get(StringVal("pi"))
	if !approxEq(pi.FVal, math.Pi) {
		t.Errorf("pi = %v, want %v", pi.FVal, math.Pi)
	}
	e := m.Get(StringVal("e"))
	if !approxEq(e.FVal, math.E) {
		t.Errorf("e = %v, want %v", e.FVal, math.E)
	}

	tests := []struct {
		fn   string
		args []Value
		want float64
	}{
		{"sqrt", []Value{FloatVal(9)}, 3},
		{"sqrt", []Value{IntVal(4)}, 2},
		{"floor", []Value{FloatVal(2.9)}, 2},
		{"ceil", []Value{FloatVal(2.1)}, 3},
		{"round", []Value{FloatVal(2.5)}, 3},
		{"abs", []Value{FloatVal(-5)}, 5},
		{"abs", []Value{IntVal(-3)}, 3},
		{"sin", []Value{FloatVal(0)}, 0},
		{"cos", []Value{FloatVal(0)}, 1},
		{"tan", []Value{FloatVal(0)}, 0},
		{"asin", []Value{FloatVal(0)}, 0},
		{"acos", []Value{FloatVal(1)}, 0},
		{"atan", []Value{FloatVal(0)}, 0},
		{"atan2", []Value{FloatVal(0), FloatVal(1)}, 0},
		{"log", []Value{FloatVal(1)}, 0},
		{"exp", []Value{FloatVal(0)}, 1},
	}

	for _, tc := range tests {
		got := callModuleFn(t, m, tc.fn, tc.args...)
		var gotF float64
		if got.Type == TypeFloat {
			gotF = got.FVal
		} else if got.Type == TypeInt {
			gotF = float64(got.IVal)
		} else {
			t.Errorf("%s: unexpected return type %s", tc.fn, got.TypeName())
			continue
		}
		if !approxEq(gotF, tc.want) {
			t.Errorf("%s(%v) = %v, want %v", tc.fn, tc.args, gotF, tc.want)
		}
	}

	// min/max with multiple args
	minV := callModuleFn(t, m, "min", FloatVal(3), FloatVal(1), FloatVal(2))
	if !approxEq(minV.FVal, 1) {
		t.Errorf("min(3,1,2) = %v, want 1", minV.FVal)
	}
	maxV := callModuleFn(t, m, "max", FloatVal(3), FloatVal(1), FloatVal(2))
	if !approxEq(maxV.FVal, 3) {
		t.Errorf("max(3,1,2) = %v, want 3", maxV.FVal)
	}

	// random: just check it returns a float in [0,1)
	rng := callModuleFn(t, m, "random")
	if rng.Type != TypeFloat || rng.FVal < 0 || rng.FVal >= 1 {
		t.Errorf("random() = %v, want float in [0,1)", rng)
	}
}
