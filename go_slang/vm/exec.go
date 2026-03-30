package slang_vm

// popFrame migrates all open upvalues and returns to the parent frame.
func (vm *VM) popFrame() {
	frame := vm.frame
	for _, uv := range frame.openUpvalues {
		uv.Migrate()
	}
	vm.frame = frame.parent
}

// prepareCall pops nargs args and a closure from the current frame's stack,
// pushes a new StackFrame, and sets vm.frame to it.
func (vm *VM) prepareCall(nargs int) {
	frame := vm.frame

	// collect args in order
	args := make([]Value, nargs)
	for i := 0; i < nargs; i++ {
		args[i] = frame.stack[frame.top-nargs+i]
	}
	frame.top -= nargs

	// pop the closure
	frame.top--
	closureVal := frame.stack[frame.top]
	if closureVal.Type != TypeClosure {
		panic("prepareCall: expected closure on stack")
	}
	closure := closureVal.Obj.(*Closure)

	newFrame := &StackFrame{
		parent:       frame,
		closure:      closure,
		openUpvalues: make(map[int]*UpvalueHolder),
	}

	if closure.GoFunc != nil {
		// native: push args, no setTop
		sz := nargs + 8
		if sz < 8 {
			sz = 8
		}
		newFrame.stack = make([]Value, sz)
		copy(newFrame.stack, args)
		newFrame.top = nargs
	} else {
		proto := closure.Prototype
		// Allocate locals area (maxVarStackSize slots, all nil) plus room
		// for expression temporaries above the locals.
		stackSize := proto.MaxVarStackSize + 256
		if stackSize < 264 {
			stackSize = 264
		}
		newFrame.stack = make([]Value, stackSize)

		nformal := proto.Nargs
		if proto.IsVarArg && nformal > 0 {
			nformal-- // last formal slot holds the vararg table
		}

		// fill normal args (pad with nil if fewer were passed)
		for i := 0; i < nformal && i < len(args); i++ {
			newFrame.stack[i] = args[i]
		}

		// build vararg table if needed
		if proto.IsVarArg {
			vt := NewSlangTable()
			for i := nformal; i < len(args); i++ {
				vt.Append(args[i])
			}
			newFrame.stack[nformal] = TableVal(vt)
		}

		// mirrors Dart's setTop(maxVarStackSize)
		newFrame.top = proto.MaxVarStackSize
	}

	vm.frame = newFrame
}

// stepNative calls a GoFunction frame and propagates the return value.
func (vm *VM) stepNative() {
	frame := vm.frame
	fn := frame.closure.GoFunc
	returned := fn(vm)
	var retVal Value
	if returned && vm.frame.top > 0 {
		retVal = vm.frame.stack[vm.frame.top-1]
	}
	vm.popFrame()
	if returned {
		vm.frame.stack[vm.frame.top] = retVal
		vm.frame.top++
	}
}

// getTableOp implements the __index metamethod chain and pushes the result.
func (vm *VM) getTableOp(tableVal Value, key Value) {
	if tableVal.Type != TypeTable {
		vm.frame.stack[vm.frame.top] = NilVal()
		vm.frame.top++
		return
	}
	t := tableVal.Obj.(*SlangTable)
	val := t.Get(key)
	if val.Type != TypeNil || t.Meta == nil {
		vm.frame.stack[vm.frame.top] = val
		vm.frame.top++
		return
	}
	indexMM := t.Meta.Get(StringVal("__index"))
	if indexMM.Type == TypeNil {
		vm.frame.stack[vm.frame.top] = NilVal()
		vm.frame.top++
		return
	}
	if indexMM.Type == TypeClosure {
		f := vm.frame
		f.stack[f.top] = indexMM
		f.top++
		f.stack[f.top] = tableVal
		f.top++
		f.stack[f.top] = key
		f.top++
		vm.prepareCall(2)
		vm.run()
		return
	}
	if indexMM.Type == TypeTable {
		vm.getTableOp(indexMM, key)
		return
	}
	vm.frame.stack[vm.frame.top] = NilVal()
	vm.frame.top++
}

// setTableOp implements the __newindex metamethod chain.
func (vm *VM) setTableOp(tableVal Value, key Value, val Value) {
	if tableVal.Type != TypeTable {
		panic("setTable: expected table")
	}
	t := tableVal.Obj.(*SlangTable)
	current := t.Get(key)
	if current.Type != TypeNil || t.Meta == nil {
		t.Set(key, val)
		return
	}
	newIndexMM := t.Meta.Get(StringVal("__newindex"))
	if newIndexMM.Type == TypeNil {
		t.Set(key, val)
		return
	}
	if newIndexMM.Type == TypeClosure {
		f := vm.frame
		f.stack[f.top] = newIndexMM
		f.top++
		f.stack[f.top] = tableVal
		f.top++
		f.stack[f.top] = key
		f.top++
		f.stack[f.top] = val
		f.top++
		vm.prepareCall(3)
		vm.run()
		return
	}
	if newIndexMM.Type == TypeTable {
		vm.setTableOp(newIndexMM, key, val)
		return
	}
	t.Set(key, val)
}

// valEqual tests Slang value equality.
func valEqual(a, b Value) bool {
	if a.Type != b.Type {
		// allow int/float cross-comparison
		if a.Type == TypeInt && b.Type == TypeFloat {
			return float64(a.IVal) == b.FVal
		}
		if a.Type == TypeFloat && b.Type == TypeInt {
			return a.FVal == float64(b.IVal)
		}
		return false
	}
	switch a.Type {
	case TypeNil:
		return true
	case TypeBool, TypeInt:
		return a.IVal == b.IVal
	case TypeFloat:
		return a.FVal == b.FVal
	case TypeString:
		return a.Obj.(string) == b.Obj.(string)
	default:
		return a.Obj == b.Obj
	}
}

// run executes the VM until vm.frame returns to the frame that was active
// when run() was invoked (i.e. vm.frame.parent at entry).
func (vm *VM) run() {
	target := vm.frame.parent
	for vm.frame != target {
		frame := vm.frame
		if frame.closure == nil {
			break
		}
		if frame.closure.GoFunc != nil {
			vm.stepNative()
			continue
		}

		instrs := frame.closure.Prototype.Instructions
		consts := frame.closure.Prototype.Constants
		stack := frame.stack

		for frame == vm.frame {
			if frame.pc >= len(instrs) {
				// implicit nil return when execution falls off the end
				vm.popFrame()
				vm.frame.stack[vm.frame.top] = NilVal()
				vm.frame.top++
				break
			}

			inst := instrs[frame.pc]
			frame.pc++

			switch inst & 0x3F {

			case uint32(opLoadConstant): // 0  iABx
				bx := int(inst >> 14)
				stack[frame.top] = consts[bx]
				frame.top++

			case uint32(opLoadBool): // 1  iABC
				b := (inst >> 23) & 0x1FF
				c := (inst >> 14) & 0x1FF
				stack[frame.top] = BoolVal(b != 0)
				frame.top++
				if c != 0 {
					frame.pc++
				}

			case uint32(opLoadClosure): // 2  iAx
				ax := int((inst >> 6) & 0x3FFFFFF)
				childProto := frame.closure.Prototype.Children[ax]
				newClosure := &Closure{
					Prototype: childProto,
					Upvalues:  make([]*UpvalueHolder, len(childProto.Upvalues)),
				}
				for i, uv := range childProto.Upvalues {
					if i == 0 && uv.Name == "_ENV" {
						newClosure.Upvalues[i] = &UpvalueHolder{value: TableVal(vm.globals)}
						continue
					}
					if uv.IsLocal {
						if existing, ok := frame.openUpvalues[uv.Index]; ok {
							newClosure.Upvalues[i] = existing
						} else {
							holder := &UpvalueHolder{frame: frame, index: uv.Index}
							frame.openUpvalues[uv.Index] = holder
							newClosure.Upvalues[i] = holder
						}
					} else {
						newClosure.Upvalues[i] = frame.closure.Upvalues[uv.Index]
					}
				}
				stack[frame.top] = ClosureVal(newClosure)
				frame.top++

			case uint32(opAdd): // 3  iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var r Value
				if a.Type == TypeInt && b.Type == TypeInt {
					r = IntVal(a.IVal + b.IVal)
				} else if a.Type == TypeFloat && b.Type == TypeFloat {
					r = FloatVal(a.FVal + b.FVal)
				} else if a.Type == TypeInt && b.Type == TypeFloat {
					r = FloatVal(float64(a.IVal) + b.FVal)
				} else {
					r = FloatVal(a.FVal + float64(b.IVal))
				}
				stack[frame.top] = r
				frame.top++

			case uint32(opSub): // 4  iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var r Value
				if a.Type == TypeInt && b.Type == TypeInt {
					r = IntVal(a.IVal - b.IVal)
				} else if a.Type == TypeFloat && b.Type == TypeFloat {
					r = FloatVal(a.FVal - b.FVal)
				} else if a.Type == TypeInt && b.Type == TypeFloat {
					r = FloatVal(float64(a.IVal) - b.FVal)
				} else {
					r = FloatVal(a.FVal - float64(b.IVal))
				}
				stack[frame.top] = r
				frame.top++

			case uint32(opMul): // 5  iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var r Value
				if a.Type == TypeInt && b.Type == TypeInt {
					r = IntVal(a.IVal * b.IVal)
				} else if a.Type == TypeFloat && b.Type == TypeFloat {
					r = FloatVal(a.FVal * b.FVal)
				} else if a.Type == TypeInt && b.Type == TypeFloat {
					r = FloatVal(float64(a.IVal) * b.FVal)
				} else {
					r = FloatVal(a.FVal * float64(b.IVal))
				}
				stack[frame.top] = r
				frame.top++

			case uint32(opDiv): // 6  iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var r Value
				if a.Type == TypeInt && b.Type == TypeInt {
					r = IntVal(a.IVal / b.IVal)
				} else if a.Type == TypeFloat && b.Type == TypeFloat {
					r = FloatVal(a.FVal / b.FVal)
				} else if a.Type == TypeInt && b.Type == TypeFloat {
					r = FloatVal(float64(a.IVal) / b.FVal)
				} else {
					r = FloatVal(a.FVal / float64(b.IVal))
				}
				stack[frame.top] = r
				frame.top++

			case uint32(opMod): // 7  iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var r Value
				if a.Type == TypeInt && b.Type == TypeInt {
					r = IntVal(a.IVal % b.IVal)
				} else {
					var fa, fb float64
					if a.Type == TypeInt {
						fa = float64(a.IVal)
					} else {
						fa = a.FVal
					}
					if b.Type == TypeInt {
						fb = float64(b.IVal)
					} else {
						fb = b.FVal
					}
					r = FloatVal(fa - float64(int64(fa/fb))*fb)
				}
				stack[frame.top] = r
				frame.top++

			case uint32(opNeg): // 8  iABC
				a := stack[frame.top-1]
				frame.top--
				if a.Type == TypeInt {
					stack[frame.top] = IntVal(-a.IVal)
				} else {
					stack[frame.top] = FloatVal(-a.FVal)
				}
				frame.top++

			case uint32(opNot): // 9  iABC
				a := stack[frame.top-1]
				frame.top--
				stack[frame.top] = BoolVal(!a.ToBool())
				frame.top++

			case uint32(opEq): // 10 iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				stack[frame.top] = BoolVal(valEqual(a, b))
				frame.top++

			case uint32(opLt): // 11 iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var result bool
				switch {
				case a.Type == TypeInt && b.Type == TypeInt:
					result = a.IVal < b.IVal
				case a.Type == TypeFloat && b.Type == TypeFloat:
					result = a.FVal < b.FVal
				case a.Type == TypeInt && b.Type == TypeFloat:
					result = float64(a.IVal) < b.FVal
				case a.Type == TypeFloat && b.Type == TypeInt:
					result = a.FVal < float64(b.IVal)
				case a.Type == TypeString && b.Type == TypeString:
					result = a.Obj.(string) < b.Obj.(string)
				}
				stack[frame.top] = BoolVal(result)
				frame.top++

			case uint32(opLeq): // 12 iABC
				b := stack[frame.top-1]
				a := stack[frame.top-2]
				frame.top -= 2
				var result bool
				switch {
				case a.Type == TypeInt && b.Type == TypeInt:
					result = a.IVal <= b.IVal
				case a.Type == TypeFloat && b.Type == TypeFloat:
					result = a.FVal <= b.FVal
				case a.Type == TypeInt && b.Type == TypeFloat:
					result = float64(a.IVal) <= b.FVal
				case a.Type == TypeFloat && b.Type == TypeInt:
					result = a.FVal <= float64(b.IVal)
				case a.Type == TypeString && b.Type == TypeString:
					result = a.Obj.(string) <= b.Obj.(string)
				}
				stack[frame.top] = BoolVal(result)
				frame.top++

			case uint32(opMove): // 13 iAsBx  replace(sbx)
				// Dart: _frame[sbx] = _frame.pop()
				// absIdx uses the post-pop top
				val := stack[frame.top-1]
				frame.top--
				bx := int((inst >> 14) & 0x3FFFF)
				sbx := bx - 0x1FFFF
				absIdx := sbx
				if sbx < 0 {
					absIdx = frame.top + sbx
				}
				frame.stack[absIdx] = val

			case uint32(opPush): // 14 iAsBx  pushStack(sbx)
				bx := int((inst >> 14) & 0x3FFFF)
				sbx := bx - 0x1FFFF
				absIdx := sbx
				if sbx < 0 {
					absIdx = frame.top + sbx
				}
				stack[frame.top] = frame.stack[absIdx]
				frame.top++

			case uint32(opPop): // 15 iABx
				keep := int((inst >> 6) & 0xFF)
				bx := int((inst >> 14) & 0x3FFFF)
				// remove `bx` values from below the top `keep` values
				newBase := frame.top - keep - bx
				copy(frame.stack[newBase:], frame.stack[frame.top-keep:frame.top])
				frame.top = newBase + keep

			case uint32(opReturn): // 16 iABx
				result := stack[frame.top-1]
				vm.popFrame()
				vm.frame.stack[vm.frame.top] = result
				vm.frame.top++
				// inner loop exits because frame != vm.frame

			case uint32(opNewTable): // 17 iABC
				t := NewSlangTable()
				stack[frame.top] = TableVal(t)
				frame.top++

			case uint32(opSetTable): // 18 iABC
				val := stack[frame.top-1]
				key := stack[frame.top-2]
				tableVal := stack[frame.top-3]
				frame.top -= 3
				vm.setTableOp(tableVal, key, val)

			case uint32(opGetTable): // 19 iABC
				key := stack[frame.top-1]
				tableVal := stack[frame.top-2]
				frame.top -= 2
				vm.getTableOp(tableVal, key)

			case uint32(opSetUpvalue): // 20 iAx
				ax := int((inst >> 6) & 0x3FFFFFF)
				frame.closure.Upvalues[ax].Set(stack[frame.top-1])
				frame.top--

			case uint32(opGetUpvalue): // 21 iAx
				ax := int((inst >> 6) & 0x3FFFFFF)
				stack[frame.top] = frame.closure.Upvalues[ax].Get()
				frame.top++

			case uint32(opCloseUpvalues): // 22 iAx
				ax := int((inst >> 6) & 0x3FFFFFF)
				for idx, uv := range frame.openUpvalues {
					if idx >= ax {
						uv.Migrate()
						delete(frame.openUpvalues, idx)
					}
				}

			case uint32(opTest): // 23 iABC
				c := (inst >> 14) & 0x1FF
				if stack[frame.top-1].ToBool() != (c != 0) {
					frame.pc++
				}
				frame.top--

			case uint32(opJump): // 24 iAsBx
				bx := int((inst >> 14) & 0x3FFFF)
				sbx := bx - 0x1FFFF
				frame.pc += sbx

			case uint32(opCall): // 25 iABC
				bx := int((inst >> 14) & 0x3FFFF)
				vm.prepareCall(bx)
				// inner loop exits because frame != vm.frame

			case uint32(opType): // 26 iABC
				frame.top--
				val := stack[frame.top]
				// check __type metamethod
				if val.Type == TypeTable {
					t := val.Obj.(*SlangTable)
					if t.Meta != nil {
						typeMM := t.Meta.Get(StringVal("__type"))
						if typeMM.Type != TypeNil {
							stack[frame.top] = typeMM
							frame.top++
							if typeMM.Type == TypeClosure {
								stack[frame.top] = val
								frame.top++
								vm.prepareCall(1)
								vm.run()
							}
							break
						}
					}
				} else if val.Type == TypeUserdata {
					ud := val.Obj.(*Userdata)
					if ud.MetaTable != nil {
						typeMM := ud.MetaTable.Get(StringVal("__type"))
						if typeMM.Type != TypeNil {
							stack[frame.top] = typeMM
							frame.top++
							if typeMM.Type == TypeClosure {
								stack[frame.top] = val
								frame.top++
								vm.prepareCall(1)
								vm.run()
							}
							break
						}
					}
				}
				stack[frame.top] = StringVal(val.TypeName())
				frame.top++
			}
		}
	}
}
