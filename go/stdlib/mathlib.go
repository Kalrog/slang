package stdlib

import (
	"math"
	"math/rand/v2"

	"slang/vm"
)

// slang/math.
func mathModule() *vm.Table {
	t := makeModule(natives{
		{"random", mathRandom},
		{"round", unary(math.Round)},
		{"floor", unary(math.Floor)},
		{"ceil", unary(math.Ceil)},
		{"abs", mathAbs},
		{"min", mathMin},
		{"max", mathMax},
		{"sqrt", unary(math.Sqrt)},
		{"sin", unary(math.Sin)},
		{"cos", unary(math.Cos)},
		{"tan", unary(math.Tan)},
		{"asin", unary(math.Asin)},
		{"acos", unary(math.Acos)},
		{"atan", unary(math.Atan)},
		{"atan2", mathAtan2},
		{"log", unary(math.Log)},
		{"exp", unary(math.Exp)},
	})
	t.SetStr("pi", vm.Float(math.Pi))
	t.SetStr("e", vm.Float(math.E))
	return t
}

func unary(f func(float64) float64) vm.NativeFunc {
	return func(th *vm.Thread, args []vm.Value) (vm.Value, error) {
		x, err := vm.ArgNumber(args, 0, "x")
		if err != nil {
			return vm.Null, err
		}
		return vm.Float(f(x)), nil
	}
}

func mathRandom(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	lo := vm.ArgNumberOr(args, 0, 0)
	hi := vm.ArgNumberOr(args, 1, 1)
	return vm.Float(rand.Float64()*(hi-lo) + lo), nil
}

func mathAbs(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	x := vm.Arg(args, 0)
	switch x.Kind() {
	case vm.KInt:
		if x.AsInt() < 0 {
			return vm.Int(-x.AsInt()), nil
		}
		return x, nil
	case vm.KFloat:
		return vm.Float(math.Abs(x.AsFloat())), nil
	}
	return vm.Null, vm.Errorf("Expected num for x got %s", x.TypeName())
}

func mathMin(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	best := vm.Float(math.Inf(1))
	for i, a := range args {
		if !a.IsNumber() {
			return vm.Null, vm.Errorf("Expected num for argument %d got %s", i, a.TypeName())
		}
		if a.AsNumber() < best.AsNumber() {
			best = a
		}
	}
	return best, nil
}

func mathMax(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	best := vm.Float(math.Inf(-1))
	for i, a := range args {
		if !a.IsNumber() {
			return vm.Null, vm.Errorf("Expected num for argument %d got %s", i, a.TypeName())
		}
		if a.AsNumber() > best.AsNumber() {
			best = a
		}
	}
	return best, nil
}

func mathAtan2(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	y, err := vm.ArgNumber(args, 0, "y")
	if err != nil {
		return vm.Null, err
	}
	x, err := vm.ArgNumber(args, 1, "x")
	if err != nil {
		return vm.Null, err
	}
	return vm.Float(math.Atan2(y, x)), nil
}
