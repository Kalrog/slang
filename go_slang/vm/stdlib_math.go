package slang_vm

import (
	"math"
	"math/rand"
)

func buildMathModule() *SlangTable {
	t := NewSlangTable()
	set := func(name string, fn GoFunction) {
		t.Set(StringVal(name), ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}))
	}
	set("random", mathRandom)
	set("round", mathRound)
	set("floor", mathFloor)
	set("ceil", mathCeil)
	set("abs", mathAbs)
	set("min", mathMin)
	set("max", mathMax)
	set("sqrt", mathSqrt)
	set("sin", mathSin)
	set("cos", mathCos)
	set("tan", mathTan)
	set("asin", mathAsin)
	set("acos", mathAcos)
	set("atan", mathAtan)
	set("atan2", mathAtan2)
	set("log", mathLog)
	set("exp", mathExp)
	t.Set(StringVal("pi"), FloatVal(math.Pi))
	t.Set(StringVal("e"), FloatVal(math.E))
	return t
}

func mathRandom(vm *VM) bool {
	switch vm.GetTop() {
	case 0:
		vm.Push(FloatVal(rand.Float64()))
	case 1:
		max := vm.GetFloatArg(0)
		vm.Push(FloatVal(rand.Float64() * max))
	default:
		min := vm.GetFloatArg(0)
		max := vm.GetFloatArg(1)
		vm.Push(FloatVal(min + rand.Float64()*(max-min)))
	}
	return true
}

func mathRound(vm *VM) bool {
	vm.Push(FloatVal(math.Round(vm.GetFloatArg(0))))
	return true
}

func mathFloor(vm *VM) bool {
	vm.Push(FloatVal(math.Floor(vm.GetFloatArg(0))))
	return true
}

func mathCeil(vm *VM) bool {
	vm.Push(FloatVal(math.Ceil(vm.GetFloatArg(0))))
	return true
}

func mathAbs(vm *VM) bool {
	vm.Push(FloatVal(math.Abs(vm.GetFloatArg(0))))
	return true
}

func mathMin(vm *VM) bool {
	n := vm.GetTop()
	if n == 0 {
		panic(&SlangException{Message: "math.min: expected at least one argument"})
	}
	min := vm.GetFloatArg(0)
	for i := 1; i < n; i++ {
		if v := vm.GetFloatArg(i); v < min {
			min = v
		}
	}
	vm.Push(FloatVal(min))
	return true
}

func mathMax(vm *VM) bool {
	n := vm.GetTop()
	if n == 0 {
		panic(&SlangException{Message: "math.max: expected at least one argument"})
	}
	max := vm.GetFloatArg(0)
	for i := 1; i < n; i++ {
		if v := vm.GetFloatArg(i); v > max {
			max = v
		}
	}
	vm.Push(FloatVal(max))
	return true
}

func mathSqrt(vm *VM) bool {
	vm.Push(FloatVal(math.Sqrt(vm.GetFloatArg(0))))
	return true
}

func mathSin(vm *VM) bool {
	vm.Push(FloatVal(math.Sin(vm.GetFloatArg(0))))
	return true
}

func mathCos(vm *VM) bool {
	vm.Push(FloatVal(math.Cos(vm.GetFloatArg(0))))
	return true
}

func mathTan(vm *VM) bool {
	vm.Push(FloatVal(math.Tan(vm.GetFloatArg(0))))
	return true
}

func mathAsin(vm *VM) bool {
	vm.Push(FloatVal(math.Asin(vm.GetFloatArg(0))))
	return true
}

func mathAcos(vm *VM) bool {
	vm.Push(FloatVal(math.Acos(vm.GetFloatArg(0))))
	return true
}

func mathAtan(vm *VM) bool {
	vm.Push(FloatVal(math.Atan(vm.GetFloatArg(0))))
	return true
}

func mathAtan2(vm *VM) bool {
	y := vm.GetFloatArg(0)
	x := vm.GetFloatArg(1)
	vm.Push(FloatVal(math.Atan2(y, x)))
	return true
}

func mathLog(vm *VM) bool {
	vm.Push(FloatVal(math.Log(vm.GetFloatArg(0))))
	return true
}

func mathExp(vm *VM) bool {
	vm.Push(FloatVal(math.Exp(vm.GetFloatArg(0))))
	return true
}
