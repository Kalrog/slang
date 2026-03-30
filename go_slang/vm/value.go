package slang_vm

type ValueType uint8

const (
	TypeNil ValueType = iota
	TypeBool
	TypeInt
	TypeFloat
	TypeString
	TypeTable
	TypeClosure
	TypeUserdata
	TypeThread
)

type Value struct {
	Type ValueType
	IVal int64      // TypeBool (0=false,1=true) and TypeInt
	FVal float64    // TypeFloat
	Obj  interface{} // TypeString→string, TypeTable→*SlangTable,
	                 // TypeClosure→*Closure, TypeUserdata→*Userdata, TypeThread→*VM
}

func NilVal() Value { return Value{Type: TypeNil} }

func BoolVal(b bool) Value {
	v := Value{Type: TypeBool}
	if b {
		v.IVal = 1
	}
	return v
}

func IntVal(i int64) Value { return Value{Type: TypeInt, IVal: i} }

func FloatVal(f float64) Value { return Value{Type: TypeFloat, FVal: f} }

func StringVal(s string) Value { return Value{Type: TypeString, Obj: s} }

func TableVal(t *SlangTable) Value { return Value{Type: TypeTable, Obj: t} }

func ClosureVal(c *Closure) Value { return Value{Type: TypeClosure, Obj: c} }

func UserdataVal(u *Userdata) Value { return Value{Type: TypeUserdata, Obj: u} }

func ThreadVal(vm *VM) Value { return Value{Type: TypeThread, Obj: vm} }

// ToBool follows Slang semantics: only nil and false are falsy.
func (v Value) ToBool() bool {
	return v.Type != TypeNil && !(v.Type == TypeBool && v.IVal == 0)
}

// TypeName returns the Slang type string for this value.
func (v Value) TypeName() string {
	switch v.Type {
	case TypeNil:
		return "null"
	case TypeBool:
		return "bool"
	case TypeInt:
		return "int"
	case TypeFloat:
		return "double"
	case TypeString:
		return "string"
	case TypeTable:
		return "table"
	case TypeClosure:
		return "function"
	case TypeUserdata:
		return "userdata"
	case TypeThread:
		return "thread"
	default:
		return "unknown"
	}
}
