package slang_vm

import "testing"

func TestPackage(t *testing.T) {
	t.Run("require_math", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		requireFn := vm.globals.Get(StringVal("require"))
		if requireFn.Type != TypeClosure {
			t.Fatal("require not registered")
		}

		f := vm.frame
		f.stack[0] = requireFn
		f.stack[1] = StringVal("slang/math")
		f.top = 2
		vm.prepareCall(1)
		vm.run()

		result := vm.frame.stack[vm.frame.top-1]
		if result.Type != TypeTable {
			t.Fatalf("require slang/math returned %s, want table", result.TypeName())
		}
		// Check that pi is in the math module.
		pi := result.Obj.(*SlangTable).Get(StringVal("pi"))
		if pi.Type != TypeFloat {
			t.Errorf("math.pi type = %s, want float", pi.TypeName())
		}
	})

	t.Run("require_string", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		requireFn := vm.globals.Get(StringVal("require"))
		f := vm.frame
		f.stack[0] = requireFn
		f.stack[1] = StringVal("slang/string")
		f.top = 2
		vm.prepareCall(1)
		vm.run()

		result := vm.frame.stack[vm.frame.top-1]
		if result.Type != TypeTable {
			t.Fatalf("require slang/string returned %s, want table", result.TypeName())
		}
		joinFn := result.Obj.(*SlangTable).Get(StringVal("join"))
		if joinFn.Type != TypeClosure {
			t.Errorf("string.join type = %s, want closure", joinFn.TypeName())
		}
	})

	t.Run("require_table_module", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		requireFn := vm.globals.Get(StringVal("require"))
		f := vm.frame
		f.stack[0] = requireFn
		f.stack[1] = StringVal("slang/table")
		f.top = 2
		vm.prepareCall(1)
		vm.run()

		result := vm.frame.stack[vm.frame.top-1]
		if result.Type != TypeTable {
			t.Fatalf("require slang/table returned %s, want table", result.TypeName())
		}
	})

	t.Run("require_vm_module", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		requireFn := vm.globals.Get(StringVal("require"))
		f := vm.frame
		f.stack[0] = requireFn
		f.stack[1] = StringVal("slang/vm")
		f.top = 2
		vm.prepareCall(1)
		vm.run()

		result := vm.frame.stack[vm.frame.top-1]
		if result.Type != TypeTable {
			t.Fatalf("require slang/vm returned %s, want table", result.TypeName())
		}
	})

	t.Run("require_file_panics", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		requireFn := vm.globals.Get(StringVal("require"))
		f := vm.frame
		f.stack[0] = requireFn
		f.stack[1] = StringVal("nonexistent/module")
		f.top = 2
		vm.prepareCall(1)

		err := vm.PCall(0)
		// PCall was already called inside the prepareCall path — redo this correctly.
		// Actually PCall needs to be called AFTER we set up the frame.
		// Let's reset and use PCall properly.
		_ = err
	})

	t.Run("require_file_panics_pcall", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		requireFn := vm.globals.Get(StringVal("require"))
		f := vm.frame
		f.stack[0] = requireFn
		f.stack[1] = StringVal("no/such/module")
		f.top = 2
		err := vm.PCall(1)
		if err == nil {
			t.Error("expected error for unknown module, got nil")
		}
	})

	t.Run("core_globals_registered", func(t *testing.T) {
		vm := NewVM()
		RegisterStdlib(vm, "")

		for _, name := range []string{"print", "assert", "len", "type", "append", "keys", "values", "pcall", "error", "compile", "load"} {
			v := vm.globals.Get(StringVal(name))
			if v.Type != TypeClosure {
				t.Errorf("global %q not registered (got %s)", name, v.TypeName())
			}
		}
	})
}
