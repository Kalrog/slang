package slang_vm

// GoFunction is the signature for Go-native functions callable from Slang.
// Returns true if a value was pushed onto the stack as a return value.
type GoFunction func(vm *VM) bool

type UpvalueDef struct {
	Name    string
	Index   int
	IsLocal bool
}

type SourceLocationInfo struct {
	FirstInstruction int
	Origin           string
	Line             int
	Col              int
}

type FunctionPrototype struct {
	MaxVarStackSize int
	Nargs           int
	IsVarArg        bool
	Instructions    []uint32
	SourceLocations []SourceLocationInfo
	Constants       []Value
	Upvalues        []UpvalueDef
	Children        []*FunctionPrototype
}

type UpvalueHolder struct {
	frame *StackFrame // nil when closed
	index int
	value Value
}

func (u *UpvalueHolder) Get() Value {
	if u.frame != nil {
		return u.frame.stack[u.index]
	}
	return u.value
}

func (u *UpvalueHolder) Set(v Value) {
	if u.frame != nil {
		u.frame.stack[u.index] = v
	} else {
		u.value = v
	}
}

// Migrate closes the upvalue by copying the stack value into the holder.
func (u *UpvalueHolder) Migrate() {
	if u.frame != nil {
		u.value = u.frame.stack[u.index]
		u.frame = nil
	}
}

type Closure struct {
	Prototype *FunctionPrototype // nil for native
	GoFunc    GoFunction         // nil for slang
	Upvalues  []*UpvalueHolder
}

type Userdata struct {
	Value     interface{}
	MetaTable *SlangTable
}

type SlangException struct {
	Message  string
	Location *SourceLocationInfo
}

func (e *SlangException) Error() string {
	return e.Message
}

type StackFrame struct {
	pc               int
	stack            []Value
	top              int
	parent           *StackFrame
	closure          *Closure
	openUpvalues     map[int]*UpvalueHolder
	exceptionHandler func(vm *VM, err error) bool
}

type VM struct {
	frame   *StackFrame
	globals *SlangTable
}

func NewVM() *VM {
	globals := NewSlangTable()
	frame := &StackFrame{
		stack:        make([]Value, 256),
		openUpvalues: make(map[int]*UpvalueHolder),
	}
	return &VM{
		frame:   frame,
		globals: globals,
	}
}
