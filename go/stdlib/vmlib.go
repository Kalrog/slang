package stdlib

import (
	"os"

	"slang/vm"
)

// slang/vm: access to closures, upvalues and bytecode.
func vmModule(v *vm.VM) *vm.Table {
	return makeModule(natives{
		{"setUpvalue", vmSetUpvalue},
		{"getUpvalue", vmGetUpvalue},
		{"upvalueNames", vmUpvalueNames},
		{"load_bytecode", vmLoadBytecode},
		{"load_bytes", vmLoadBytes},
		{"to_bytes", vmToBytes},
		{"embedded", vmEmbedded},
		{"disassemble", vmDisassemble},
		{"load_proto", vmLoadProto},
	})
}

// load_proto(proto): turns a prototype table produced by the compiler into a
// function. Layout:
//
//	{code: {ints}, locations: {{pc, origin, line, column}}, constants: {{kind, value}},
//	 upvalues: {{name, index, is_local}}, children: {proto}, max_stack, nargs, is_vararg}
func vmLoadProto(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	t, err := vm.ArgTable(args, 0, "proto")
	if err != nil {
		return vm.Null, err
	}
	p, err := protoFromTable(t, 0)
	if err != nil {
		return vm.Null, err
	}
	return vm.FunctionValue(th.VM().Load(p)), nil
}

func protoFromTable(t *vm.Table, depth int) (*vm.FunctionProto, error) {
	if depth > 200 {
		return nil, vm.Errorf("load_proto: nesting too deep")
	}
	p := &vm.FunctionProto{}
	p.MaxStack = int(t.GetStr("max_stack").AsInt())
	p.NArgs = int(t.GetStr("nargs").AsInt())
	p.IsVarArg = t.GetStr("is_vararg").Truthy()
	code := t.GetStr("code").AsTable()
	if code == nil {
		return nil, vm.Errorf("load_proto: missing code")
	}
	p.Code = make([]uint32, 0, code.Len())
	for _, c := range code.Values() {
		if c.Kind() != vm.KInt {
			return nil, vm.Errorf("load_proto: instruction is not an int")
		}
		p.Code = append(p.Code, uint32(c.AsInt()))
	}
	if locs := t.GetStr("locations").AsTable(); locs != nil {
		for _, l := range locs.Values() {
			lt := l.AsTable()
			if lt == nil {
				continue
			}
			p.Locs = append(p.Locs, vm.LocInfo{
				FirstPC: int(lt.GetInt(0).AsInt()),
				Origin:  lt.GetInt(1).String(),
				Line:    int(lt.GetInt(2).AsInt()),
				Column:  int(lt.GetInt(3).AsInt()),
			})
		}
	}
	if consts := t.GetStr("constants").AsTable(); consts != nil {
		for _, c := range consts.Values() {
			ct := c.AsTable()
			if ct == nil {
				return nil, vm.Errorf("load_proto: constant must be {kind, value}")
			}
			kind := ct.GetInt(0).AsString()
			val := ct.GetInt(1)
			switch kind {
			case "int":
				if val.Kind() == vm.KFloat {
					val = vm.Int(int64(val.AsFloat()))
				}
			case "double":
				if val.Kind() == vm.KInt {
					val = vm.Float(float64(val.AsInt()))
				}
			case "string", "bool":
			case "null":
				val = vm.Null
			default:
				return nil, vm.Errorf("load_proto: unknown constant kind %q", kind)
			}
			p.Consts = append(p.Consts, val)
		}
	}
	if ups := t.GetStr("upvalues").AsTable(); ups != nil {
		for _, u := range ups.Values() {
			ut := u.AsTable()
			if ut == nil {
				return nil, vm.Errorf("load_proto: upvalue must be {name, index, is_local}")
			}
			p.Upvals = append(p.Upvals, vm.UpvalDesc{
				Name:    ut.GetInt(0).AsString(),
				Index:   int(ut.GetInt(1).AsInt()),
				IsLocal: ut.GetInt(2).Truthy(),
			})
		}
	}
	if children := t.GetStr("children").AsTable(); children != nil {
		for _, c := range children.Values() {
			ct := c.AsTable()
			if ct == nil {
				return nil, vm.Errorf("load_proto: child must be a table")
			}
			child, err := protoFromTable(ct, depth+1)
			if err != nil {
				return nil, err
			}
			p.Children = append(p.Children, child)
		}
	}
	return p, nil
}

func vmSetUpvalue(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	cl, err := vm.ArgFunction(args, 0, "closure")
	if err != nil {
		return vm.Null, err
	}
	name, err := vm.ArgString(args, 1, "name")
	if err != nil {
		return vm.Null, err
	}
	if i := cl.UpvalueIndex(name); i >= 0 {
		cl.ReplaceUpvalue(i, vm.Arg(args, 2))
	}
	return vm.Null, nil
}

func vmGetUpvalue(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	cl, err := vm.ArgFunction(args, 0, "closure")
	if err != nil {
		return vm.Null, err
	}
	name, err := vm.ArgString(args, 1, "name")
	if err != nil {
		return vm.Null, err
	}
	return cl.GetUpvalue(cl.UpvalueIndex(name)), nil
}

func vmUpvalueNames(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	cl, err := vm.ArgFunction(args, 0, "closure")
	if err != nil {
		return vm.Null, err
	}
	t := vm.NewTable(0, 0)
	if cl.Proto != nil {
		for _, u := range cl.Proto.Upvals {
			t.Append(vm.String(u.Name))
		}
	}
	return vm.TableValue(t), nil
}

func vmLoadBytecode(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	path, err := vm.ArgString(args, 0, "path")
	if err != nil {
		return vm.Null, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return vm.Null, vm.Errorf("cannot read %s: %v", path, err)
	}
	cl, err := th.VM().LoadBytes(data)
	if err != nil {
		return vm.Null, vm.Errorf("%s: %v", path, err)
	}
	return vm.FunctionValue(cl), nil
}

func vmLoadBytes(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	data, err := vm.ArgString(args, 0, "bytes")
	if err != nil {
		return vm.Null, err
	}
	cl, err := th.VM().LoadBytes([]byte(data))
	if err != nil {
		return vm.Null, err
	}
	return vm.FunctionValue(cl), nil
}

func vmToBytes(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	cl, err := vm.ArgFunction(args, 0, "closure")
	if err != nil {
		return vm.Null, err
	}
	if cl.Proto == nil {
		return vm.Null, vm.Errorf("cannot serialise a native function")
	}
	return vm.String(string(vm.Encode(cl.Proto, vm.ArgBool(args, 1, false)))), nil
}

func vmEmbedded(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	name, err := vm.ArgString(args, 0, "name")
	if err != nil {
		return vm.Null, err
	}
	cl, err := th.VM().EmbeddedModule(name)
	if err != nil {
		return vm.Null, err
	}
	return vm.FunctionValue(cl), nil
}

func vmDisassemble(th *vm.Thread, args []vm.Value) (vm.Value, error) {
	cl, err := vm.ArgFunction(args, 0, "closure")
	if err != nil {
		return vm.Null, err
	}
	if cl.Proto == nil {
		return vm.String("native function " + cl.Name), nil
	}
	return vm.String(vm.Disassemble(cl.Proto)), nil
}
