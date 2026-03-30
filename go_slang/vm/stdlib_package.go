package slang_vm

import (
	"bytes"
	"os"
)

type packageRegistry struct {
	loaded *SlangTable // "package.loaded" — maps name → module value
}

func newPackageRegistry() *packageRegistry {
	return &packageRegistry{loaded: NewSlangTable()}
}

// Preload registers a module table under the given name.
func (r *packageRegistry) Preload(name string, t *SlangTable) {
	r.loaded.Set(StringVal(name), TableVal(t))
}

// requireFn implements the require(name) built-in.
// Checks preloaded modules first, then tries file-based loading (.slb then .slang).
func requireFn(vm *VM, pkg *packageRegistry) bool {
	name := vm.GetStringArg(0)
	val := pkg.loaded.Get(StringVal(name))
	if val.Type != TypeNil && val.ToBool() {
		vm.Push(val)
		return true
	}

	// Try name.slb — load pre-compiled bytecode directly.
	if data, err := os.ReadFile(name + ".slb"); err == nil {
		proto, loadErr := LoadPrototype(bytes.NewReader(data))
		if loadErr != nil {
			panic(&SlangException{Message: "require: " + name + ": " + loadErr.Error()})
		}
		cl := vm.wrapPrototype(proto)
		closureVal := ClosureVal(cl)
		pkg.loaded.Set(StringVal(name), closureVal)
		vm.Push(closureVal)
		return true
	}

	// Try name.slang — compile then load.
	if src, err := os.ReadFile(name + ".slang"); err == nil {
		if bootstrapCompiler.Type == TypeNil {
			panic(&SlangException{Message: "require: bootstrap compiler not loaded, cannot compile " + name})
		}
		byteTable, invokeErr := vm.Invoke(bootstrapCompiler, []Value{StringVal(string(src))})
		if invokeErr != nil {
			panic(&SlangException{Message: "require: compile " + name + ": " + invokeErr.Error()})
		}
		t := byteTable.Obj.(*SlangTable)
		n := int(t.Length())
		buf := make([]byte, n)
		for i := 0; i < n; i++ {
			v := t.Get(IntVal(int64(i + 1)))
			buf[i] = byte(v.IVal)
		}
		proto, loadErr := LoadPrototype(bytes.NewReader(buf))
		if loadErr != nil {
			panic(&SlangException{Message: "require: load " + name + ": " + loadErr.Error()})
		}
		cl := vm.wrapPrototype(proto)
		closureVal := ClosureVal(cl)
		pkg.loaded.Set(StringVal(name), closureVal)
		vm.Push(closureVal)
		return true
	}

	panic(&SlangException{Message: "require: module not found: " + name})
}

// loadBootstrapCompiler reads a .slb file, runs it as a module, and wires up
// the compile function and slang/compiler preload.
func loadBootstrapCompiler(vm *VM, path string, pkg *packageRegistry) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	proto, err := LoadPrototype(bytes.NewReader(data))
	if err != nil {
		return err
	}
	cl := vm.wrapPrototype(proto)
	moduleVal, invokeErr := vm.Invoke(ClosureVal(cl), nil)
	if invokeErr != nil {
		return invokeErr
	}
	if moduleVal.Type == TypeTable {
		pkg.loaded.Set(StringVal("slang/compiler"), moduleVal)
		compileFn := moduleVal.Obj.(*SlangTable).Get(StringVal("compile"))
		if compileFn.Type == TypeClosure {
			SetBootstrapCompiler(compileFn)
		}
	}
	return nil
}

// RegisterStdlib registers all built-in libraries with the VM.
// If bootstrapPath is non-empty, the .slb file at that path is loaded as the
// bootstrap compiler and SetBootstrapCompiler is called with its compile function.
func RegisterStdlib(vm *VM, bootstrapPath string) {
	pkg := newPackageRegistry()

	registerCoreLib(vm)

	pkg.Preload("slang/math", buildMathModule())
	pkg.Preload("slang/string", buildStringModule())
	pkg.Preload("slang/table", buildTableModule())
	pkg.Preload("slang/vm", buildVMModule())
	pkg.Preload("slang/bitwise", buildBitwiseModule())

	if bootstrapPath != "" {
		if err := loadBootstrapCompiler(vm, bootstrapPath, pkg); err != nil {
			panic(&SlangException{Message: "bootstrap: " + err.Error()})
		}
	}

	vm.RegisterGoFunction("require", func(vm *VM) bool {
		return requireFn(vm, pkg)
	})
}
