package vm

// UpvalDesc describes how a closure captures one upvalue: either a local slot
// of the enclosing function (IsLocal) or one of its upvalues.
type UpvalDesc struct {
	Name    string
	Index   int
	IsLocal bool
}

// LocInfo maps the instruction range starting at FirstPC to a source position.
type LocInfo struct {
	FirstPC int
	Origin  string
	Line    int
	Column  int
}

// FunctionProto is a compiled function: bytecode plus everything needed to
// instantiate closures from it.
type FunctionProto struct {
	Code     []uint32
	Consts   []Value
	Upvals   []UpvalDesc
	Children []*FunctionProto
	Locs     []LocInfo
	MaxStack int
	NArgs    int
	IsVarArg bool
}

// Location returns the source position of the instruction at pc, or nil.
func (p *FunctionProto) Location(pc int) *LocInfo {
	var res *LocInfo
	for i := range p.Locs {
		if p.Locs[i].FirstPC <= pc {
			res = &p.Locs[i]
		} else {
			break
		}
	}
	return res
}

// Origin is the source origin of the function (empty if unknown).
func (p *FunctionProto) Origin() string {
	if len(p.Locs) > 0 {
		return p.Locs[0].Origin
	}
	return ""
}
