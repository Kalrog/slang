// Package stdlib provides the Go-implemented part of the slang standard
// library: core globals and the native modules slang/vm, slang/os,
// slang/string, slang/math and slang/thread. The rest of the library is
// written in slang (see slang/lib) and loaded from embedded bytecode.
package stdlib

import (
	"fmt"

	"slang/vm"
)

type native struct {
	Name string
	Fn   vm.NativeFunc
}

type natives []native

func makeModule(ns natives) *vm.Table {
	t := vm.NewTable(0, len(ns))
	for _, n := range ns {
		t.SetStr(n.Name, vm.FunctionValue(vm.NewNative(n.Name, n.Fn)))
	}
	return t
}

// Open installs the core globals and the preloaded native modules into v.
func Open(v *vm.VM) {
	pkgs := vm.NewTable(0, 4)
	pkgs.SetStr("loaders", vm.TableValue(vm.NewTable(0, 0)))
	pkgs.SetStr("preloaded", vm.TableValue(vm.NewTable(0, 16)))
	sp := vm.NewTable(1, 0)
	sp.Append(vm.String("."))
	pkgs.SetStr("searchPaths", vm.TableValue(sp))
	v.Packages = pkgs
	v.SetGlobal("__PACKAGES", vm.TableValue(pkgs))

	openCore(v)
	Preload(v, "slang/vm", vm.TableValue(vmModule(v)))
	Preload(v, "slang/os", vm.TableValue(osModule(v)))
	Preload(v, "slang/string", vm.TableValue(stringModule()))
	Preload(v, "slang/math", vm.TableValue(mathModule()))
	Preload(v, "slang/thread", vm.TableValue(threadModule()))
}

// Preload registers a module value so that require(name) finds it.
func Preload(v *vm.VM, name string, module vm.Value) {
	entry := vm.NewTable(2, 0)
	entry.Append(vm.True)
	entry.Append(module)
	v.Packages.GetStr("preloaded").AsTable().SetStr(name, vm.TableValue(entry))
}

// Boot runs the slang-side bootstrap modules from the embedded file system:
// slang/package (require), slang/std (module, run) and slang/compiler
// (compile). A module's result is registered as preloaded, so that
// require("slang/compiler") is the instance that boot created.
func Boot(v *vm.VM) error {
	for _, name := range []string{"slang/package", "slang/std", "slang/compiler"} {
		cl, err := v.EmbeddedModule(name)
		if err != nil {
			return fmt.Errorf("loading %s: %w", name, err)
		}
		if cl == nil {
			return fmt.Errorf("embedded module %s not found", name)
		}
		res, err := v.Call(vm.FunctionValue(cl))
		if err != nil {
			return err
		}
		if !res.IsNull() {
			Preload(v, name, res)
		}
	}
	return nil
}
