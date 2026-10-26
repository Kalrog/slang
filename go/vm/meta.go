package vm

// Operator metamethods. A table or userdata whose metatable defines one of
// these functions takes part in the corresponding operation:
//
//	__add __sub __mul __div __mod __pow   binary arithmetic (a, b), consulted
//	                                      when the built-in operation fails;
//	                                      a's metatable is tried before b's
//	__unm                                 unary minus (a)
//	__eq                                  equality, only when both operands are
//	                                      tables (or both userdata)
//	__lt __le                             ordering (a, b); > and >= are the
//	                                      negation of <= and <
//	__call                                calling the value (self, args...)
//	__tostring                            print, string, concat and error
//	__len                                 len
//
// Metamethods run as nested calls, so they may not yield.

// metaOf returns the metatable of a table or userdata value, or nil.
func metaOf(v Value) *Table {
	switch v.k {
	case KTable:
		return v.o.(*Table).Meta
	case KUserdata:
		return v.o.(*Userdata).Meta
	}
	return nil
}

// metamethod looks up the function name in the metatable of a and then of b.
func metamethod(a, b Value, name string) Value {
	if m := metaOf(a); m != nil {
		if f := m.GetStr(name); f.k == KFunction {
			return f
		}
	}
	if m := metaOf(b); m != nil {
		if f := m.GetStr(name); f.k == KFunction {
			return f
		}
	}
	return Null
}

func arithMetaName(op uint32) string {
	switch op {
	case opAdd:
		return "__add"
	case opSub:
		return "__sub"
	case opMul:
		return "__mul"
	case opDiv:
		return "__div"
	case opMod:
		return "__mod"
	case opPow:
		return "__pow"
	}
	return ""
}

// arithMeta performs a binary arithmetic operation; when the built-in
// operation does not apply, the operands' metamethod is called instead.
func (th *Thread) arithMeta(op uint32, a, b Value) (Value, error) {
	r, err := arith(op, a, b)
	if err == nil {
		return r, nil
	}
	if f := metamethod(a, b, arithMetaName(op)); f.k == KFunction {
		return th.Call(f, a, b)
	}
	return Null, err
}

// ToString converts v to its display string, through __tostring if the value
// has one.
func (th *Thread) ToString(v Value) (string, error) {
	if m := metaOf(v); m != nil {
		if f := m.GetStr("__tostring"); f.k == KFunction {
			r, err := th.Call(f, v)
			if err != nil {
				return "", err
			}
			return r.String(), nil
		}
	}
	return v.String(), nil
}

// Len implements len: the length of a string or table, or __len.
func (th *Thread) Len(v Value) (Value, error) {
	if m := metaOf(v); m != nil {
		if f := m.GetStr("__len"); f.k == KFunction {
			return th.Call(f, v)
		}
	}
	switch v.k {
	case KTable:
		return Int(int64(v.o.(*Table).Len())), nil
	case KString:
		return Int(int64(len(v.o.(string)))), nil
	}
	return Null, Errorf("len requires a table or string")
}
