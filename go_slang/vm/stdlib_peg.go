package slang_vm

import (
	"go_slang/peg"
)

// anyToSlangValue converts a Go any value (from PEG parser results) into a slang Value.
func anyToSlangValue(v any) Value {
	if v == nil {
		return NilVal()
	}
	switch val := v.(type) {
	case string:
		return StringVal(val)
	case int:
		return IntVal(int64(val))
	case int64:
		return IntVal(val)
	case float64:
		return FloatVal(val)
	case bool:
		return BoolVal(val)
	case []any:
		t := NewSlangTable()
		for _, item := range val {
			t.Append(anyToSlangValue(item))
		}
		return TableVal(t)
	case peg.Token:
		t := NewSlangTable()
		t.Set(StringVal("type"), StringVal(val.Type))
		t.Set(StringVal("value"), StringVal(val.Value))
		return TableVal(t)
	case *SlangTable:
		return TableVal(val)
	case Value:
		return val
	default:
		return NilVal()
	}
}

// slangValueToAny converts a slang Value back to a Go any value for PEG map callbacks.
func slangValueToAny(v Value) any {
	switch v.Type {
	case TypeNil:
		return nil
	case TypeBool:
		return v.IVal != 0
	case TypeInt:
		return v.IVal
	case TypeFloat:
		return v.FVal
	case TypeString:
		return v.Obj.(string)
	case TypeTable:
		return v.Obj.(*SlangTable)
	case TypeUserdata:
		return v.Obj.(*Userdata).Value
	default:
		return nil
	}
}

func pegStringFn(vm *VM) bool {
	s := vm.GetStringArg(0)
	vm.Push(UserdataVal(&Userdata{Value: peg.String(s)}))
	return true
}

func pegPatternFn(vm *VM) bool {
	re := vm.GetStringArg(0)
	vm.Push(UserdataVal(&Userdata{Value: peg.Pattern(re)}))
	return true
}

func pegAnyCharFn(vm *VM) bool {
	vm.Push(UserdataVal(&Userdata{Value: peg.AnyChar()}))
	return true
}

func pegSeqFn(vm *VM) bool {
	n := vm.GetTop()
	parsers := make([]peg.Parser, n)
	for i := 0; i < n; i++ {
		parsers[i] = vm.GetUserdataArg(i).Value.(peg.Parser)
	}
	vm.Push(UserdataVal(&Userdata{Value: peg.Seq(parsers...)}))
	return true
}

func pegChoiceFn(vm *VM) bool {
	n := vm.GetTop()
	parsers := make([]peg.Parser, n)
	for i := 0; i < n; i++ {
		parsers[i] = vm.GetUserdataArg(i).Value.(peg.Parser)
	}
	vm.Push(UserdataVal(&Userdata{Value: peg.Choice(parsers...)}))
	return true
}

func pegStarFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	vm.Push(UserdataVal(&Userdata{Value: peg.Star(p)}))
	return true
}

func pegLazyStarFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	limit := vm.GetUserdataArg(1).Value.(peg.Parser)
	vm.Push(UserdataVal(&Userdata{Value: peg.LazyStar(p, limit)}))
	return true
}

func pegLazyPlusFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	limit := vm.GetUserdataArg(1).Value.(peg.Parser)
	vm.Push(UserdataVal(&Userdata{Value: peg.LazyPlus(p, limit)}))
	return true
}

func pegSeparatedStarFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	sep := vm.GetUserdataArg(1).Value.(peg.Parser)
	vm.Push(UserdataVal(&Userdata{Value: peg.SeperatedStar(p, sep, false)}))
	return true
}

func pegSeparatedPlusFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	sep := vm.GetUserdataArg(1).Value.(peg.Parser)
	vm.Push(UserdataVal(&Userdata{Value: peg.SeperatedPlus(p, sep, false)}))
	return true
}

func pegKeepFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	i := int(vm.GetIntArg(1))
	vm.Push(UserdataVal(&Userdata{Value: peg.Keep(p, i)}))
	return true
}

func pegTokenFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	typeStr := vm.GetStringArg(1)
	vm.Push(UserdataVal(&Userdata{Value: peg.ToToken(p, typeStr)}))
	return true
}

func pegStartFn(vm *VM) bool {
	vm.Push(UserdataVal(&Userdata{Value: peg.Start()}))
	return true
}

func pegEndFn(vm *VM) bool {
	vm.Push(UserdataVal(&Userdata{Value: peg.End()}))
	return true
}

func pegParseFn(vm *VM) bool {
	p := vm.GetUserdataArg(0).Value.(peg.Parser)
	input := vm.GetStringArg(1)
	ctx := p.ParseOn(peg.NewContext(input))
	result := NewSlangTable()
	if ctx.IsSuccess() {
		result.Set(StringVal("ok"), BoolVal(true))
		result.Set(StringVal("value"), anyToSlangValue(ctx.Value))
		result.Set(StringVal("position"), IntVal(int64(ctx.Position)))
	} else {
		result.Set(StringVal("ok"), BoolVal(false))
		result.Set(StringVal("error"), StringVal(ctx.Error.Error()))
		result.Set(StringVal("position"), IntVal(int64(ctx.Position)))
	}
	vm.Push(TableVal(result))
	return true
}

// buildPegModule constructs the slang/peg module table.
// vm is captured by the peg.map closure so it can Invoke slang callbacks.
func buildPegModule(outerVM *VM) *SlangTable {
	t := NewSlangTable()
	setFn := func(name string, fn GoFunction) {
		t.Set(StringVal(name), ClosureVal(&Closure{GoFunc: fn, Upvalues: make([]*UpvalueHolder, 0)}))
	}

	setFn("string", pegStringFn)
	setFn("pattern", pegPatternFn)
	setFn("any_char", pegAnyCharFn)
	setFn("seq", pegSeqFn)
	setFn("choice", pegChoiceFn)
	setFn("star", pegStarFn)
	setFn("lazy_star", pegLazyStarFn)
	setFn("lazy_plus", pegLazyPlusFn)
	setFn("separated_star", pegSeparatedStarFn)
	setFn("separated_plus", pegSeparatedPlusFn)
	setFn("keep", pegKeepFn)
	setFn("token", pegTokenFn)
	setFn("start", pegStartFn)
	setFn("end", pegEndFn)
	setFn("parse", pegParseFn)

	// peg.map must capture outerVM to Invoke slang closures during parsing.
	setFn("map", func(vm *VM) bool {
		p := vm.GetUserdataArg(0).Value.(peg.Parser)
		mapperCl := vm.stackArg(1)
		mapped := peg.Map(p, func(v any) any {
			result, err := outerVM.Invoke(mapperCl, []Value{anyToSlangValue(v)})
			if err != nil {
				panic(err)
			}
			return slangValueToAny(result)
		})
		vm.Push(UserdataVal(&Userdata{Value: mapped}))
		return true
	})

	return t
}
