package vm

import (
	"math"
	"strings"
)

// Opcodes. The encoding is the one of the Dart implementation:
//
//	31       23       14       6     0
//	|b=9bits |c=9bits |a=8bits |op=6|
//	|    bx=18bits    |a=8bits |op=6|   sbx = bx - 0x1FFFF
//	|    ax=26bits             |op=6|
const (
	opLoadConstant = iota // push K[bx]
	opLoadBool            // push bool(b); if c: pc++
	opLoadClosure         // push closure(children[ax])
	opAdd
	opSub
	opMul
	opDiv
	opMod
	opNeg
	opNot
	opEq
	opLt
	opLeq
	opMove          // stack[sbx] = pop()
	opPush          // push stack[sbx]
	opPop           // keep top a, drop bx beneath
	opReturn        // return top
	opNewTable      // push {} (b array hint, c hash hint)
	opSetTable      // t[k] = v (pops 3)
	opGetTable      // push t[k] (pops 2)
	opSetUpvalue    // upvals[ax] = pop()
	opGetUpvalue    // push upvals[ax]
	opCloseUpvalues // close upvalues >= ax
	opTest          // if truthy(top) != c: pc++ ; pop
	opJump          // pc += sbx
	opCall          // call with bx args
	opType          // replace top with its type
	opPow           // a ^ b
	opBand          // a & b
	opBor           // a | b
	opBxor          // a ~ b
	opShl           // a << b
	opShr           // a >> b (arithmetic)
	opBnot          // ~a
	opCallSpread    // call with bx fixed args followed by a list of the rest
	numOpcodes
)

var opNames = [...]string{
	"loadConstant", "loadBool", "loadClosure", "add", "sub", "mul", "div", "mod",
	"neg", "not", "eq", "lt", "leq", "move", "push", "pop", "returnOp", "newTable",
	"setTable", "getTable", "setUpvalue", "getUpvalue", "closeUpvalues", "test",
	"jump", "call", "type", "pow", "band", "bor", "bxor", "shl", "shr", "bnot", "callSpread",
}

func opName(op uint32) string {
	if int(op) < len(opNames) {
		return opNames[op]
	}
	return "op?"
}

func (th *Thread) absIndex(base, idx int) int {
	if idx < 0 {
		return th.top + idx
	}
	return base + idx
}

// run executes frames until the frame depth drops back to stopDepth.
func (th *Thread) run(stopDepth int) (err error) {
	th.runDepth++
	defer func() { th.runDepth-- }()
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(*Error); ok {
				err = th.handleError(e, stopDepth)
				if err == nil {
					// a protected frame absorbed it; keep running
					err = th.run(stopDepth)
				}
				return
			}
			panic(r)
		}
	}()
outer:
	for {
		n := len(th.frames)
		if n <= stopDepth {
			return nil
		}
		fr := th.frames[n-1]
		if fr.cl.Proto == nil {
			return Errorf("internal error: native frame in interpreter loop")
		}
		proto := fr.cl.Proto
		code := proto.Code
		consts := proto.Consts
		base := fr.base
		pc := fr.pc
		for {
			ins := code[pc]
			pc++
			fr.pc = pc
			switch ins & 0x3F {
			case opLoadConstant:
				th.push(consts[ins>>14])
			case opLoadBool:
				th.push(Bool((ins>>23)&0x1FF != 0))
				if (ins>>14)&0x1FF != 0 {
					pc++
				}
			case opLoadClosure:
				th.push(FunctionValue(th.makeClosure(fr, proto.Children[ins>>6])))
			case opAdd:
				b := th.stack[th.top-1]
				a := th.stack[th.top-2]
				th.top -= 2
				if a.k == KInt && b.k == KInt {
					th.push(Int(a.n + b.n))
					continue
				}
				r, err := th.arithMeta(opAdd, a, b)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				th.push(r)
			case opSub:
				b := th.stack[th.top-1]
				a := th.stack[th.top-2]
				th.top -= 2
				if a.k == KInt && b.k == KInt {
					th.push(Int(a.n - b.n))
					continue
				}
				r, err := th.arithMeta(opSub, a, b)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				th.push(r)
			case opMul, opDiv, opMod, opPow, opBand, opBor, opBxor, opShl, opShr:
				b := th.stack[th.top-1]
				a := th.stack[th.top-2]
				th.top -= 2
				r, err := th.arithMeta(ins&0x3F, a, b)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				th.push(r)
			case opNeg:
				a := th.stack[th.top-1]
				switch a.k {
				case KInt:
					th.stack[th.top-1] = Int(-a.n)
				case KFloat:
					th.stack[th.top-1] = Float(-a.AsFloat())
				default:
					if f := metamethod(a, Null, "__unm"); f.k == KFunction {
						r, err := th.Call(f, a)
						if err != nil {
							if e := th.handleError(err, stopDepth); e != nil {
								return e
							}
							continue outer
						}
						th.stack[th.top-1] = r
						continue
					}
					if e := th.handleError(Errorf("attempt to negate a %s value", a.TypeName()), stopDepth); e != nil {
						return e
					}
					continue outer
				}
			case opNot:
				th.stack[th.top-1] = Bool(!th.stack[th.top-1].Truthy())
			case opBnot:
				a := th.stack[th.top-1]
				if a.k == KInt {
					th.stack[th.top-1] = Int(^a.n)
					continue
				}
				if x, ok := exactInt(a); ok {
					th.stack[th.top-1] = Int(^x)
					continue
				}
				if f := metamethod(a, Null, "__bnot"); f.k == KFunction {
					r, err := th.Call(f, a)
					if err != nil {
						if e := th.handleError(err, stopDepth); e != nil {
							return e
						}
						continue outer
					}
					th.stack[th.top-1] = r
					continue
				}
				if e := th.handleError(bitError(a, "~", a), stopDepth); e != nil {
					return e
				}
				continue outer
			case opEq:
				b := th.stack[th.top-1]
				a := th.stack[th.top-2]
				th.top--
				if a.k == b.k && (a.k == KTable || a.k == KUserdata) {
					if f := metamethod(a, b, "__eq"); f.k == KFunction {
						r, err := th.Call(f, a, b)
						if err != nil {
							th.top--
							if e := th.handleError(err, stopDepth); e != nil {
								return e
							}
							continue outer
						}
						th.stack[th.top-1] = Bool(r.Truthy())
						continue
					}
				}
				th.stack[th.top-1] = Bool(Equals(a, b))
			case opLt, opLeq:
				b := th.stack[th.top-1]
				a := th.stack[th.top-2]
				th.top--
				var r bool
				if a.k == KInt && b.k == KInt {
					if ins&0x3F == opLt {
						r = a.n < b.n
					} else {
						r = a.n <= b.n
					}
				} else if a.IsNumber() && b.IsNumber() {
					x, y := a.AsNumber(), b.AsNumber()
					if ins&0x3F == opLt {
						r = x < y
					} else {
						r = x <= y
					}
				} else {
					name, op := "__lt", "<"
					if ins&0x3F == opLeq {
						name, op = "__le", "<="
					}
					if f := metamethod(a, b, name); f.k == KFunction {
						res, err := th.Call(f, a, b)
						if err != nil {
							th.top--
							if e := th.handleError(err, stopDepth); e != nil {
								return e
							}
							continue outer
						}
						th.stack[th.top-1] = Bool(res.Truthy())
						continue
					}
					th.top--
					if e := th.handleError(Errorf("attempt to compare %s %s %s", a.TypeName(), op, b.TypeName()), stopDepth); e != nil {
						return e
					}
					continue outer
				}
				th.stack[th.top-1] = Bool(r)
			case opMove:
				v := th.stack[th.top-1]
				th.top--
				th.stack[th.absIndex(base, int(ins>>14)-0x1FFFF)] = v
			case opPush:
				th.push(th.stack[th.absIndex(base, int(ins>>14)-0x1FFFF)])
			case opPop:
				keep := int((ins >> 6) & 0xFF)
				drop := int(ins >> 14)
				if keep > 0 {
					copy(th.stack[th.top-drop-keep:th.top-drop], th.stack[th.top-keep:th.top])
				}
				th.top -= drop
			case opReturn:
				res := th.stack[th.top-1]
				fnIdx := base - 1
				prot := fr.protected
				th.popFrame()
				th.top = fnIdx
				if prot {
					res = okResult(res)
				}
				th.push(res)
				if len(th.frames) == stopDepth {
					return nil
				}
				continue outer
			case opNewTable:
				th.push(TableValue(NewTable(int((ins>>23)&0x1FF), int((ins>>14)&0x1FF))))
			case opSetTable:
				val := th.stack[th.top-1]
				key := th.stack[th.top-2]
				obj := th.stack[th.top-3]
				th.top -= 3
				if obj.k == KTable {
					t := obj.o.(*Table)
					if t.Meta == nil && key.k == KString {
						if s := key.o.(string); s != "meta" {
							t.SetStr(s, val)
							continue
						}
					}
				}
				if err := th.setTable(obj, key, val); err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
			case opGetTable:
				key := th.stack[th.top-1]
				obj := th.stack[th.top-2]
				th.top--
				if obj.k == KTable {
					t := obj.o.(*Table)
					var v Value
					if key.k == KString {
						v = t.GetStr(key.o.(string))
					} else if key.k == KInt {
						v = t.GetInt(key.n)
					} else {
						v = t.Get(key)
					}
					if v.k != KNull || t.Meta == nil {
						th.stack[th.top-1] = v
						continue
					}
				}
				th.top--
				v, err := th.getTable(obj, key)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				th.push(v)
			case opSetUpvalue:
				v := th.stack[th.top-1]
				th.top--
				fr.cl.Upvals[ins>>6].Set(v)
			case opGetUpvalue:
				th.push(fr.cl.Upvals[ins>>6].Get())
			case opCloseUpvalues:
				th.closeUpvalues(base + int(ins>>6))
			case opTest:
				v := th.stack[th.top-1]
				th.top--
				if v.Truthy() != ((ins>>14)&0x1FF != 0) {
					pc++
				}
			case opJump:
				pc += int(ins>>14) - 0x1FFFF
			case opCallSpread:
				fixed := int(ins >> 14)
				list := th.stack[th.top-1]
				if list.k != KTable {
					if e := th.handleError(Errorf("attempt to spread a %s value", list.TypeName()), stopDepth); e != nil {
						return e
					}
					continue outer
				}
				items := list.o.(*Table).arr
				th.top--
				for _, v := range items {
					th.push(v)
				}
				nargs := fixed + len(items)
				fnIdx := th.top - nargs - 1
				isSlang, err := th.precall(fnIdx, nargs, false)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				if isSlang {
					continue outer
				}
			case opCall:
				nargs := int(ins >> 14)
				fnIdx := th.top - nargs - 1
				isSlang, err := th.precall(fnIdx, nargs, false)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				if isSlang {
					continue outer
				}
			case opType:
				v := th.stack[th.top-1]
				th.top--
				r, err := th.TypeOf(v)
				if err != nil {
					if e := th.handleError(err, stopDepth); e != nil {
						return e
					}
					continue outer
				}
				th.push(r)
			default:
				return Errorf("unknown opcode %d", ins&0x3F)
			}
		}
	}
}

// exactInt converts an integer, or a float with an integral value, to an int.
func exactInt(v Value) (int64, bool) {
	switch v.k {
	case KInt:
		return v.n, true
	case KFloat:
		f := v.AsFloat()
		if f == math.Trunc(f) && f >= -9.2e18 && f <= 9.2e18 {
			return int64(f), true
		}
	}
	return 0, false
}

func isBitOp(op uint32) bool {
	return op >= opBand && op <= opShr
}

func bitError(a Value, sym string, b Value) error {
	if a.IsNumber() && b.IsNumber() {
		return Errorf("number has no integer representation in bitwise operation (%s)", sym)
	}
	if a.k == b.k {
		return Errorf("attempt to perform bitwise operation (%s) on %s values", sym, a.TypeName())
	}
	return Errorf("attempt to perform bitwise operation (%s) on %s and %s", sym, a.TypeName(), b.TypeName())
}

// bitop implements & | ~ << >> on integers (floats with integral values
// convert). Shifts by 64 or more give 0 (or -1 for a negative value shifted
// right); negative shift amounts are an error.
func bitop(op uint32, a, b Value) (Value, error) {
	x, okx := exactInt(a)
	y, oky := exactInt(b)
	if !okx || !oky {
		return Null, bitError(a, opSymbol(op), b)
	}
	switch op {
	case opBand:
		return Int(x & y), nil
	case opBor:
		return Int(x | y), nil
	case opBxor:
		return Int(x ^ y), nil
	case opShl:
		if y < 0 {
			return Null, Errorf("negative shift amount")
		}
		if y >= 64 {
			return Int(0), nil
		}
		return Int(x << uint(y)), nil
	case opShr:
		if y < 0 {
			return Null, Errorf("negative shift amount")
		}
		if y >= 64 {
			y = 63
		}
		return Int(x >> uint(y)), nil
	}
	return Null, Errorf("unknown bitwise operation")
}

func arith(op uint32, a, b Value) (Value, error) {
	if isBitOp(op) {
		return bitop(op, a, b)
	}
	if a.k == KInt && b.k == KInt {
		x, y := a.n, b.n
		switch op {
		case opAdd:
			return Int(x + y), nil
		case opSub:
			return Int(x - y), nil
		case opMul:
			return Int(x * y), nil
		case opDiv:
			return Float(float64(x) / float64(y)), nil
		case opMod:
			if y == 0 {
				return Null, Errorf("integer modulo by zero")
			}
			r := x % y
			if r < 0 {
				if y < 0 {
					r -= y
				} else {
					r += y
				}
			}
			return Int(r), nil
		case opPow:
			if y >= 0 {
				r := int64(1)
				base := x
				e := y
				for e > 0 {
					if e&1 == 1 {
						r *= base
					}
					base *= base
					e >>= 1
				}
				return Int(r), nil
			}
			return Float(math.Pow(float64(x), float64(y))), nil
		}
	}
	if a.IsNumber() && b.IsNumber() {
		x, y := a.AsNumber(), b.AsNumber()
		switch op {
		case opAdd:
			return Float(x + y), nil
		case opSub:
			return Float(x - y), nil
		case opMul:
			return Float(x * y), nil
		case opDiv:
			return Float(x / y), nil
		case opMod:
			r := math.Mod(x, y)
			if r < 0 {
				r += math.Abs(y)
			}
			return Float(r), nil
		case opPow:
			return Float(math.Pow(x, y)), nil
		}
	}
	if a.k == KString {
		switch op {
		case opAdd:
			if b.k == KString {
				return String(a.o.(string) + b.o.(string)), nil
			}
		case opMul:
			if b.k == KInt {
				n := b.n
				if n < 0 {
					n = 0
				}
				return String(strings.Repeat(a.o.(string), int(n))), nil
			}
		}
	}
	return Null, Errorf("attempt to perform arithmetic (%s) on %s and %s", opSymbol(op), a.TypeName(), b.TypeName())
}

func opSymbol(op uint32) string {
	switch op {
	case opAdd:
		return "+"
	case opSub:
		return "-"
	case opMul:
		return "*"
	case opDiv:
		return "/"
	case opMod:
		return "%"
	case opPow:
		return "^"
	case opBand:
		return "&"
	case opBor:
		return "|"
	case opBxor:
		return "~"
	case opShl:
		return "<<"
	case opShr:
		return ">>"
	case opBnot:
		return "~"
	}
	return opName(op)
}

func keyDesc(key Value) string {
	if key.k == KString {
		return "\"" + key.o.(string) + "\""
	}
	return key.String()
}

// getTable implements indexing with __index metamethods.
func (th *Thread) getTable(obj, key Value) (Value, error) {
	for depth := 0; depth < 100; depth++ {
		var meta *Table
		switch obj.k {
		case KTable:
			t := obj.o.(*Table)
			if raw := t.Get(key); raw.k != KNull {
				return raw, nil
			}
			meta = t.Meta
		case KUserdata:
			meta = obj.o.(*Userdata).Meta
		case KNull:
			return Null, Errorf("attempt to index a null value (key %s)", keyDesc(key))
		default:
			return Null, nil
		}
		if meta == nil {
			return Null, nil
		}
		idx := meta.GetStr("__index")
		switch idx.k {
		case KFunction:
			return th.Call(idx, obj, key)
		case KTable:
			obj = idx
		default:
			return Null, nil
		}
	}
	return Null, Errorf("__index chain too long")
}

// setTable implements assignment with __newindex metamethods.
func (th *Thread) setTable(obj, key, val Value) error {
	for depth := 0; depth < 100; depth++ {
		switch obj.k {
		case KTable:
			t := obj.o.(*Table)
			if key.k == KNull {
				return Errorf("table index is null")
			}
			if t.Meta == nil {
				return rawSet(t, key, val)
			}
			if cur := t.Get(key); cur.k != KNull {
				return rawSet(t, key, val)
			}
			ni := t.Meta.GetStr("__newindex")
			switch ni.k {
			case KNull:
				return rawSet(t, key, val)
			case KFunction:
				_, err := th.Call(ni, obj, key, val)
				return err
			case KTable:
				obj = ni
			default:
				return nil
			}
		case KUserdata:
			u := obj.o.(*Userdata)
			if u.Meta != nil {
				ni := u.Meta.GetStr("__newindex")
				switch ni.k {
				case KFunction:
					_, err := th.Call(ni, obj, key, val)
					return err
				case KTable:
					obj = ni
					continue
				case KNull:
				default:
					return nil
				}
			}
			return Errorf("cannot set value on userdata")
		case KNull:
			return Errorf("attempt to index a null value (key %s)", keyDesc(key))
		default:
			return Errorf("attempt to index a %s value (key %s)", obj.TypeName(), keyDesc(key))
		}
	}
	return Errorf("__newindex chain too long")
}

func rawSet(t *Table, key, val Value) error {
	if key.k == KString && key.o.(string) == "meta" {
		switch val.k {
		case KTable:
			t.Meta = val.o.(*Table)
		case KNull:
			t.Meta = nil
		default:
			return Errorf("meta must be a table, got %s", val.TypeName())
		}
		return nil
	}
	t.Set(key, val)
	return nil
}

// TypeOf implements the type operation including the __type metafield.
func (th *Thread) TypeOf(v Value) (Value, error) {
	var meta *Table
	var def string
	switch v.k {
	case KTable:
		meta = v.o.(*Table).Meta
		def = "table"
	case KUserdata:
		meta = v.o.(*Userdata).Meta
		def = "userdata"
	default:
		return String(v.TypeName()), nil
	}
	if meta != nil {
		ty := meta.GetStr("__type")
		switch ty.k {
		case KNull:
		case KFunction:
			return th.Call(ty, v)
		default:
			return ty, nil
		}
	}
	return String(def), nil
}
