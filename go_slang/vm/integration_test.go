package slang_vm

import (
	"os"
	"testing"
)

// TestIntegration loads a pre-compiled Slang program from testdata/, runs it
// in the Go VM, and reports every test case the script recorded as failed.
//
// The script (testdata/integration_vm_test.slang) exercises:
//   - Arithmetic (int, float, mixed)
//   - Comparison operators
//   - Variables and assignment
//   - If/else and nested conditionals
//   - User-defined functions
//   - Recursion (factorial, fibonacci)
//   - Closures and upvalue capture
//   - Tables (literal, get/set, nested, metatables)
//   - For loops and break
//   - Built-ins: type, len, string, append
//   - Stdlib: slang/math, slang/string
//   - Error handling: pcall / error
//
// The script returns: {passed: int, failed: int, failures: table_of_names}
// Each failure becomes a t.Errorf so the test suite reports all issues at once.
func TestIntegration(t *testing.T) {
	f, err := os.Open("testdata/integration_vm_test.slb")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	proto, err := LoadPrototype(f)
	if err != nil {
		t.Fatalf("LoadPrototype: %v", err)
	}

	vm := NewVM()
	RegisterStdlib(vm, "")

	if err := vm.LoadAndRun(proto); err != nil {
		t.Fatalf("LoadAndRun: %v", err)
	}

	// The script's return value is at the top of the root frame's stack.
	if vm.frame.top == 0 {
		t.Fatal("script returned no value")
	}
	result := vm.frame.stack[vm.frame.top-1]
	if result.Type != TypeTable {
		t.Fatalf("script return type = %s, want table", result.TypeName())
	}
	res := result.Obj.(*SlangTable)

	passedVal := res.Get(StringVal("passed"))
	failedVal := res.Get(StringVal("failed"))
	failuresVal := res.Get(StringVal("failures"))

	passed := int(passedVal.IVal)
	failed := int(failedVal.IVal)

	t.Logf("integration: %d passed, %d failed", passed, failed)

	if failed == 0 {
		return
	}

	if failuresVal.Type != TypeTable {
		t.Fatalf("failures field type = %s, want table", failuresVal.TypeName())
	}
	failures := failuresVal.Obj.(*SlangTable)
	n := failures.Length()
	for i := 0; i < n; i++ {
		name := failures.Get(IntVal(int64(i)))
		t.Errorf("FAIL: %s", name.Obj.(string))
	}
}
