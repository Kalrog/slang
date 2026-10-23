package vm

import (
	"strings"
)

// Status of a coroutine.
type Status uint8

const (
	StatusInit Status = iota
	StatusRunning
	StatusSuspended
	StatusDead
)

func (s Status) String() string {
	switch s {
	case StatusInit:
		return "init"
	case StatusRunning:
		return "running"
	case StatusSuspended:
		return "suspended"
	default:
		return "dead"
	}
}

// Frame is one activation record. base is the stack index of the first
// argument/local; the callee itself sits at base-1 and receives the result.
type Frame struct {
	cl        *Closure
	pc        int
	base      int
	protected bool
}

// Thread is an execution context (the main thread or a coroutine) with its own
// value stack and frame stack.
type Thread struct {
	vm         *VM
	id         int
	stack      []Value
	top        int
	frames     []*Frame
	pool       []*Frame
	openUpvals []*Upvalue
	status     Status
	entry      *Closure
	runDepth   int
	yielded    Value
	isMain     bool
}

const (
	initialStack = 256
	maxStack     = 1 << 24
	maxFrames    = 1 << 20
)

func newThread(vm *VM, entry *Closure) *Thread {
	vm.nextThreadID++
	return &Thread{
		vm:     vm,
		id:     vm.nextThreadID,
		stack:  make([]Value, initialStack),
		entry:  entry,
		status: StatusInit,
	}
}

func (th *Thread) VM() *VM        { return th.vm }
func (th *Thread) ID() int        { return th.id }
func (th *Thread) Status() Status { return th.status }
func (th *Thread) IsMain() bool   { return th.isMain }
func (th *Thread) Depth() int     { return len(th.frames) }

func (th *Thread) push(v Value) {
	if th.top == len(th.stack) {
		th.grow(th.top + 1)
	}
	th.stack[th.top] = v
	th.top++
}

func (th *Thread) grow(need int) {
	n := len(th.stack) * 2
	for n < need {
		n *= 2
	}
	if n > maxStack {
		panic(Errorf("stack overflow"))
	}
	ns := make([]Value, n)
	copy(ns, th.stack[:th.top])
	th.stack = ns
}

func (th *Thread) ensure(need int) {
	if need > len(th.stack) {
		th.grow(need)
	}
}

func (th *Thread) pushFrame(cl *Closure, base int, protected bool) *Frame {
	if len(th.frames) >= maxFrames {
		panic(Errorf("stack overflow (too many nested calls)"))
	}
	var fr *Frame
	if n := len(th.pool); n > 0 {
		fr = th.pool[n-1]
		th.pool = th.pool[:n-1]
	} else {
		fr = &Frame{}
	}
	fr.cl = cl
	fr.pc = 0
	fr.base = base
	fr.protected = protected
	th.frames = append(th.frames, fr)
	return fr
}

func (th *Thread) popFrame() {
	n := len(th.frames) - 1
	fr := th.frames[n]
	if fr.cl.Proto != nil {
		th.closeUpvalues(fr.base)
	}
	th.frames = th.frames[:n]
	fr.cl = nil
	th.pool = append(th.pool, fr)
}

func (th *Thread) findOrCreateUpvalue(idx int) *Upvalue {
	ups := th.openUpvals
	i := len(ups) - 1
	for ; i >= 0; i-- {
		if ups[i].idx == idx {
			return ups[i]
		}
		if ups[i].idx < idx {
			break
		}
	}
	u := &Upvalue{th: th, idx: idx}
	ups = append(ups, nil)
	copy(ups[i+2:], ups[i+1:])
	ups[i+1] = u
	th.openUpvals = ups
	return u
}

func (th *Thread) closeUpvalues(from int) {
	ups := th.openUpvals
	i := len(ups)
	for i > 0 && ups[i-1].idx >= from {
		i--
		ups[i].close()
		ups[i] = nil
	}
	th.openUpvals = ups[:i]
}

func (th *Thread) makeClosure(fr *Frame, child *FunctionProto) *Closure {
	cl := &Closure{Proto: child, Upvals: make([]*Upvalue, len(child.Upvals))}
	for i, uv := range child.Upvals {
		if uv.IsLocal {
			cl.Upvals[i] = th.findOrCreateUpvalue(fr.base + uv.Index)
		} else if uv.Index < len(fr.cl.Upvals) && fr.cl.Upvals[uv.Index] != nil {
			cl.Upvals[i] = fr.cl.Upvals[uv.Index]
		} else {
			cl.Upvals[i] = &Upvalue{}
		}
	}
	return cl
}

// Call invokes fn with args from Go and returns its result. Errors raised by
// slang code come back as *Error.
func (th *Thread) Call(fn Value, args ...Value) (Value, error) {
	fnIdx := th.top
	th.push(fn)
	for _, a := range args {
		th.push(a)
	}
	isSlang, err := th.precall(fnIdx, len(args), false)
	if err != nil {
		if err == errYield {
			th.popFrame()
			err = th.toError(Errorf("attempt to yield across a native call boundary"))
		}
		th.top = fnIdx
		return Null, err
	}
	if isSlang {
		if err := th.run(len(th.frames) - 1); err != nil {
			th.top = fnIdx
			return Null, err
		}
	}
	res := th.stack[fnIdx]
	th.top = fnIdx
	return res, nil
}

// precall sets up a call of the value at fnIdx with nargs arguments above it.
// Native functions are executed immediately and their result replaces the
// callee slot; for slang functions a frame is pushed and true is returned.
func (th *Thread) precall(fnIdx, nargs int, protected bool) (bool, error) {
	fn := th.stack[fnIdx]
	if fn.k != KFunction {
		return false, Errorf("attempt to call a %s value", fn.TypeName())
	}
	cl := fn.o.(*Closure)
	if cl.special == specPCall {
		if nargs < 1 {
			return false, Errorf("pcall requires at least one argument")
		}
		copy(th.stack[fnIdx:th.top-1], th.stack[fnIdx+1:th.top])
		th.top--
		return th.precall(fnIdx, nargs-1, true)
	}
	if cl.Native != nil {
		th.pushFrame(cl, fnIdx+1, protected)
		res, err := cl.Native(th, th.stack[fnIdx+1:th.top])
		if err == errYield {
			return false, errYield
		}
		if err != nil {
			e := th.toError(err)
			th.popFrame()
			if protected {
				th.top = fnIdx
				th.push(errResult(e))
				return false, nil
			}
			return false, e
		}
		th.popFrame()
		th.top = fnIdx
		if protected {
			res = okResult(res)
		}
		th.push(res)
		return false, nil
	}
	p := cl.Proto
	base := fnIdx + 1
	nparams := p.NArgs
	if p.IsVarArg {
		nparams--
	}
	if nargs > nparams {
		if p.IsVarArg {
			extra := NewTable(nargs-nparams, 0)
			extra.arr = append(extra.arr, th.stack[base+nparams:base+nargs]...)
			th.stack[base+nparams] = TableValue(extra)
			th.top = base + nparams + 1
		} else {
			th.top = base + nparams
		}
	} else {
		for th.top < base+nparams {
			th.push(Null)
		}
		if p.IsVarArg {
			th.push(TableValue(NewTable(0, 0)))
		}
	}
	need := base + p.MaxStack
	th.ensure(need + 8)
	for th.top < need {
		th.stack[th.top] = Null
		th.top++
	}
	th.pushFrame(cl, base, protected)
	return true, nil
}

// toError converts any error into a *Error with location and traceback.
func (th *Thread) toError(err error) *Error {
	e, ok := err.(*Error)
	if !ok {
		e = &Error{Message: err.Error()}
	}
	if e.Loc == nil {
		e.Loc = th.currentLocation()
	}
	if e.Trace == "" {
		e.Trace = th.Traceback()
	}
	return e
}

// currentLocation is the source position of the innermost slang frame.
func (th *Thread) currentLocation() *Location {
	for i := len(th.frames) - 1; i >= 0; i-- {
		fr := th.frames[i]
		if fr.cl.Proto == nil {
			continue
		}
		pc := fr.pc - 1
		if pc < 0 {
			pc = 0
		}
		if l := fr.cl.Proto.Location(pc); l != nil {
			return &Location{Origin: l.Origin, Line: l.Line, Column: l.Column}
		}
		return nil
	}
	return nil
}

// Traceback renders the frame stack, innermost first.
func (th *Thread) Traceback() string {
	var sb strings.Builder
	sb.WriteString("stack traceback:")
	for i := len(th.frames) - 1; i >= 0; i-- {
		fr := th.frames[i]
		sb.WriteString("\n  at ")
		if fr.cl.Proto == nil {
			sb.WriteString("[native ")
			sb.WriteString(fr.cl.Name)
			sb.WriteString("]")
			continue
		}
		pc := fr.pc - 1
		if pc < 0 {
			pc = 0
		}
		if l := fr.cl.Proto.Location(pc); l != nil {
			sb.WriteString(l.Origin)
			sb.WriteString(":")
			sb.WriteString(itoa(l.Line))
			sb.WriteString(":")
			sb.WriteString(itoa(l.Column))
		} else {
			sb.WriteString("function (no source info)")
		}
	}
	return sb.String()
}

// handleError deals with an error raised inside run: it either transfers
// control to the nearest protected call of this run loop or unwinds the loop's
// frames and returns the error to the caller.
func (th *Thread) handleError(err error, stopDepth int) error {
	if err == errYield {
		if th.runDepth == 1 && !th.isMain {
			return errYield
		}
		th.popFrame()
		err = Errorf("attempt to yield across a native call boundary")
	}
	e := th.toError(err)
	for i := len(th.frames) - 1; i >= stopDepth; i-- {
		if th.frames[i].protected {
			fnIdx := th.frames[i].base - 1
			for len(th.frames) > i {
				th.popFrame()
			}
			th.top = fnIdx
			th.push(errResult(e))
			return nil
		}
	}
	for len(th.frames) > stopDepth {
		th.popFrame()
	}
	return e
}

// Resume runs a coroutine until it yields or finishes. The returned value is
// the yielded value or the function result. Resuming a dead coroutine
// returns null.
func (co *Thread) Resume(args []Value) (Value, error) {
	switch co.status {
	case StatusDead:
		return Null, nil
	case StatusRunning:
		return Null, Errorf("cannot resume a running coroutine")
	case StatusInit:
		co.status = StatusRunning
		co.top = 0
		co.push(FunctionValue(co.entry))
		for _, a := range args {
			co.push(a)
		}
		isSlang, err := co.precall(0, len(args), false)
		if err != nil {
			return co.finish(err)
		}
		if !isSlang {
			return co.finish(nil)
		}
	case StatusSuspended:
		co.status = StatusRunning
		fr := co.frames[len(co.frames)-1]
		fnIdx := fr.base - 1
		co.popFrame()
		co.top = fnIdx
		v := Null
		if len(args) > 0 {
			v = args[0]
		}
		co.push(v)
	}
	err := co.run(0)
	return co.finish(err)
}

func (co *Thread) finish(err error) (Value, error) {
	if err == errYield {
		co.status = StatusSuspended
		v := co.yielded
		co.yielded = Null
		return v, nil
	}
	co.status = StatusDead
	if err != nil {
		for len(co.frames) > 0 {
			co.popFrame()
		}
		co.top = 0
		return Null, err
	}
	res := Null
	if co.top > 0 {
		res = co.stack[co.top-1]
	}
	co.top = 0
	return res, nil
}

// Yield suspends the current coroutine with v. It must be returned from a
// native function as its error to take effect.
func (th *Thread) Yield(v Value) error {
	if th.isMain {
		return Errorf("cannot yield from the main thread")
	}
	th.yielded = v
	return errYield
}

func itoa(i int) string {
	return strings.TrimSpace(strings.Repeat(" ", 0) + fmtInt(i))
}

func fmtInt(i int) string {
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var b [20]byte
	p := len(b)
	for i > 0 {
		p--
		b[p] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		p--
		b[p] = '-'
	}
	return string(b[p:])
}
