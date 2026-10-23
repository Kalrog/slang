package vm

// NativeFunc is a function implemented in Go. args aliases the thread's value
// stack and is only valid during the call; copy it if you need to keep it.
type NativeFunc func(th *Thread, args []Value) (Value, error)

const (
	specNone uint8 = iota
	specPCall
)

// Closure is a callable value: either a slang function (Proto + captured
// upvalues) or a Go function.
type Closure struct {
	Proto   *FunctionProto
	Native  NativeFunc
	Name    string
	Upvals  []*Upvalue
	special uint8
}

// NewNative wraps a Go function as a slang function value.
func NewNative(name string, fn NativeFunc) *Closure {
	return &Closure{Native: fn, Name: name}
}

// PCallClosure returns the special pcall function. It is handled inside the
// interpreter so that errors are caught without a nested Go call and so that
// coroutines may yield inside a protected call.
func PCallClosure() *Closure {
	return &Closure{Native: func(th *Thread, args []Value) (Value, error) {
		return Null, Errorf("pcall must be called from slang")
	}, Name: "pcall", special: specPCall}
}

// UpvalueIndex returns the index of the named upvalue, or -1.
func (c *Closure) UpvalueIndex(name string) int {
	if c.Proto == nil {
		return -1
	}
	for i, u := range c.Proto.Upvals {
		if u.Name == name {
			return i
		}
	}
	return -1
}

// GetUpvalue reads upvalue i.
func (c *Closure) GetUpvalue(i int) Value {
	if i < 0 || i >= len(c.Upvals) || c.Upvals[i] == nil {
		return Null
	}
	return c.Upvals[i].Get()
}

// ReplaceUpvalue gives upvalue i a fresh closed cell holding v. Other closures
// that shared the old cell are not affected (this is how module{} works).
func (c *Closure) ReplaceUpvalue(i int, v Value) {
	if i < 0 || i >= len(c.Upvals) {
		return
	}
	c.Upvals[i] = &Upvalue{v: v}
}

// Upvalue is a captured variable. While open it refers to a slot of a thread's
// stack; once closed it owns the value.
type Upvalue struct {
	th  *Thread
	idx int
	v   Value
}

// NewUpvalue creates a closed upvalue holding v.
func NewUpvalue(v Value) *Upvalue { return &Upvalue{v: v} }

func (u *Upvalue) Get() Value {
	if u.th != nil {
		return u.th.stack[u.idx]
	}
	return u.v
}

func (u *Upvalue) Set(v Value) {
	if u.th != nil {
		u.th.stack[u.idx] = v
		return
	}
	u.v = v
}

func (u *Upvalue) close() {
	if u.th != nil {
		u.v = u.th.stack[u.idx]
		u.th = nil
	}
}
