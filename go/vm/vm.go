package vm

import (
	"bufio"
	"fmt"
	"io"
	"io/fs"
	"os"
	"runtime/debug"
)

// VM holds the state shared by all threads: globals, the package registry and
// the standard streams.
type VM struct {
	Globals      *Table
	Main         *Thread
	Packages     *Table // __PACKAGES
	Args         []string
	Stdout       io.Writer
	Stdin        *bufio.Reader
	Embedded     fs.FS // optional file system with precompiled modules (name.slb)
	nextThreadID int
}

// New creates a VM with an empty global table and no library functions.
func New() *VM {
	vm := &VM{
		Globals: NewTable(0, 64),
		Stdout:  os.Stdout,
		Stdin:   bufio.NewReader(os.Stdin),
	}
	vm.Main = newThread(vm, nil)
	vm.Main.isMain = true
	vm.Main.status = StatusRunning
	return vm
}

// NewThread creates a coroutine that will run entry when first resumed.
func (vm *VM) NewThread(entry *Closure) *Thread { return newThread(vm, entry) }

// Load instantiates a top-level prototype. Its _ENV upvalue is bound to the
// global table.
func (vm *VM) Load(p *FunctionProto) *Closure {
	cl := &Closure{Proto: p, Upvals: make([]*Upvalue, len(p.Upvals))}
	for i := range cl.Upvals {
		if i == 0 && p.Upvals[0].Name == "_ENV" {
			cl.Upvals[0] = &Upvalue{v: TableValue(vm.Globals)}
		} else {
			cl.Upvals[i] = &Upvalue{}
		}
	}
	return cl
}

// LoadBytes decodes a .slb container and instantiates it.
func (vm *VM) LoadBytes(data []byte) (*Closure, error) {
	p, err := Decode(data)
	if err != nil {
		return nil, err
	}
	return vm.Load(p), nil
}

// Call runs fn on the main thread.
func (vm *VM) Call(fn Value, args ...Value) (res Value, err error) {
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(*Error); ok {
				err = vm.Main.toError(e)
				return
			}
			err = &Error{
				Message: fmt.Sprintf("internal VM error: %v", r),
				Loc:     vm.Main.currentLocation(),
				Trace:   vm.Main.Traceback() + "\n" + string(debug.Stack()),
			}
		}
	}()
	return vm.Main.Call(fn, args...)
}

func (vm *VM) GetGlobal(name string) Value { return vm.Globals.GetStr(name) }

func (vm *VM) SetGlobal(name string, v Value) { vm.Globals.SetStr(name, v) }

// Register installs a Go function as a global.
func (vm *VM) Register(name string, fn NativeFunc) {
	vm.Globals.SetStr(name, FunctionValue(NewNative(name, fn)))
}

// Flush flushes Stdout if it is buffered.
func (vm *VM) Flush() {
	if w, ok := vm.Stdout.(interface{ Flush() error }); ok {
		w.Flush()
	}
}

// EmbeddedModule loads "<name>.slb" from the embedded file system, or returns
// nil if there is none.
func (vm *VM) EmbeddedModule(name string) (*Closure, error) {
	if vm.Embedded == nil {
		return nil, nil
	}
	data, err := fs.ReadFile(vm.Embedded, name+".slb")
	if err != nil {
		return nil, nil
	}
	return vm.LoadBytes(data)
}
