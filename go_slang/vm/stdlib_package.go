package slang_vm

type packageRegistry struct {
	loaded *SlangTable // "package.loaded" — maps name → module table
}

func newPackageRegistry() *packageRegistry {
	return &packageRegistry{loaded: NewSlangTable()}
}

// Preload registers a module table under the given name.
func (r *packageRegistry) Preload(name string, t *SlangTable) {
	r.loaded.Set(StringVal(name), TableVal(t))
}

// requireFn implements the require(name) built-in.
// Returns preloaded modules; panics for file-based loading.
func requireFn(vm *VM, pkg *packageRegistry) bool {
	name := vm.GetStringArg(0)
	val := pkg.loaded.Get(StringVal(name))
	if val.Type != TypeNil && val.ToBool() {
		vm.Push(val)
		return true
	}
	panic(&SlangException{Message: "require: file loading not implemented; will be implemented in slang"})
}

// RegisterStdlib registers all built-in libraries with the VM.
// compile, load, and require (file-loading) are stubbed.
func RegisterStdlib(vm *VM) {
	pkg := newPackageRegistry()

	registerCoreLib(vm)

	pkg.Preload("slang/math", buildMathModule())
	pkg.Preload("slang/string", buildStringModule())
	pkg.Preload("slang/table", buildTableModule())
	pkg.Preload("slang/vm", buildVMModule())

	vm.RegisterGoFunction("require", func(vm *VM) bool {
		return requireFn(vm, pkg)
	})
}
