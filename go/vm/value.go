package vm

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Kind is the dynamic type tag of a Value.
type Kind uint8

const (
	KNull Kind = iota
	KBool
	KInt
	KFloat
	KString
	KTable
	KFunction
	KUserdata
	KThread
)

var kindNames = [...]string{"null", "bool", "int", "double", "string", "table", "function", "userdata", "thread"}

func (k Kind) String() string { return kindNames[k] }

// Value is a slang value. null, bool, int and double never allocate; the other
// kinds keep a pointer (or a Go string) in o.
type Value struct {
	k Kind
	n int64
	o any
}

// Null is the slang null value (the zero Value).
var Null = Value{}

// True and False are the boolean values.
var (
	True  = Value{k: KBool, n: 1}
	False = Value{k: KBool}
)

func Bool(b bool) Value {
	if b {
		return True
	}
	return False
}
func Int(i int64) Value     { return Value{k: KInt, n: i} }
func Float(f float64) Value { return Value{k: KFloat, n: int64(math.Float64bits(f))} }
func String(s string) Value { return Value{k: KString, o: s} }

func TableValue(t *Table) Value {
	if t == nil {
		return Null
	}
	return Value{k: KTable, o: t}
}

func FunctionValue(c *Closure) Value {
	if c == nil {
		return Null
	}
	return Value{k: KFunction, o: c}
}

func UserdataValue(u *Userdata) Value {
	if u == nil {
		return Null
	}
	return Value{k: KUserdata, o: u}
}

func ThreadValue(t *Thread) Value {
	if t == nil {
		return Null
	}
	return Value{k: KThread, o: t}
}

// NewUserdata wraps an arbitrary Go value.
func NewUserdata(v any, meta *Table) *Userdata { return &Userdata{Value: v, Meta: meta} }

// Userdata carries any Go value into slang, optionally with a metatable.
type Userdata struct {
	Value any
	Meta  *Table
}

func (v Value) Kind() Kind       { return v.k }
func (v Value) IsNull() bool     { return v.k == KNull }
func (v Value) IsNumber() bool   { return v.k == KInt || v.k == KFloat }
func (v Value) IsString() bool   { return v.k == KString }
func (v Value) IsTable() bool    { return v.k == KTable }
func (v Value) IsFunction() bool { return v.k == KFunction }
func (v Value) TypeName() string { return kindNames[v.k] }

// Truthy reports whether the value counts as true: everything except null and false.
func (v Value) Truthy() bool { return !(v.k == KNull || (v.k == KBool && v.n == 0)) }

func (v Value) AsBool() bool     { return v.n != 0 }
func (v Value) AsInt() int64     { return v.n }
func (v Value) AsFloat() float64 { return math.Float64frombits(uint64(v.n)) }

// AsNumber converts an int or double to float64.
func (v Value) AsNumber() float64 {
	if v.k == KInt {
		return float64(v.n)
	}
	return v.AsFloat()
}

func (v Value) AsString() string {
	s, _ := v.o.(string)
	return s
}

func (v Value) AsTable() *Table {
	t, _ := v.o.(*Table)
	return t
}

func (v Value) AsFunction() *Closure {
	c, _ := v.o.(*Closure)
	return c
}

func (v Value) AsUserdata() *Userdata {
	u, _ := v.o.(*Userdata)
	return u
}

func (v Value) AsThread() *Thread {
	t, _ := v.o.(*Thread)
	return t
}

// String renders the value the way the Dart implementation did (used by print).
func (v Value) String() string {
	switch v.k {
	case KNull:
		return "null"
	case KBool:
		if v.n != 0 {
			return "true"
		}
		return "false"
	case KInt:
		return strconv.FormatInt(v.n, 10)
	case KFloat:
		return formatFloat(v.AsFloat())
	case KString:
		return v.o.(string)
	case KTable:
		return v.o.(*Table).String()
	case KFunction:
		c := v.o.(*Closure)
		if c.Native != nil {
			return "native function"
		}
		return "function"
	case KUserdata:
		return fmt.Sprint(v.o.(*Userdata).Value)
	case KThread:
		return "thread"
	}
	return "?"
}

// formatFloat follows the Dart/JavaScript number to string rules.
func formatFloat(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	case f == 0:
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	s := strconv.FormatFloat(f, 'e', -1, 64)
	neg := false
	if s[0] == '-' {
		neg = true
		s = s[1:]
	}
	epos := strings.IndexByte(s, 'e')
	mant := s[:epos]
	exp, _ := strconv.Atoi(s[epos+1:])
	digits := strings.Replace(mant, ".", "", 1)
	k := len(digits)
	n := exp + 1
	var out string
	switch {
	case k <= n && n <= 21:
		out = digits + strings.Repeat("0", n-k) + ".0"
	case 0 < n && n <= 21:
		out = digits[:n] + "." + digits[n:]
	case -6 < n && n <= 0:
		out = "0." + strings.Repeat("0", -n) + digits
	default:
		e := n - 1
		sign := "+"
		if e < 0 {
			sign = "-"
			e = -e
		}
		if k == 1 {
			out = digits + "e" + sign + strconv.Itoa(e)
		} else {
			out = digits[:1] + "." + digits[1:] + "e" + sign + strconv.Itoa(e)
		}
	}
	if neg {
		out = "-" + out
	}
	return out
}

// Equals implements slang ==: numeric across int/double, structural for tables,
// prototype identity for functions, identity otherwise.
func Equals(a, b Value) bool {
	switch a.k {
	case KNull:
		return b.k == KNull
	case KBool:
		return b.k == KBool && a.n == b.n
	case KInt:
		if b.k == KInt {
			return a.n == b.n
		}
		if b.k == KFloat {
			return float64(a.n) == b.AsFloat()
		}
		return false
	case KFloat:
		if b.k == KFloat {
			return a.AsFloat() == b.AsFloat()
		}
		if b.k == KInt {
			return a.AsFloat() == float64(b.n)
		}
		return false
	case KString:
		return b.k == KString && a.o.(string) == b.o.(string)
	case KTable:
		return b.k == KTable && a.o.(*Table).Equals(b.o.(*Table))
	case KFunction:
		if b.k != KFunction {
			return false
		}
		ca, cb := a.o.(*Closure), b.o.(*Closure)
		if ca == cb {
			return true
		}
		return ca.Proto != nil && ca.Proto == cb.Proto
	default:
		return a.k == b.k && a.o == b.o
	}
}
