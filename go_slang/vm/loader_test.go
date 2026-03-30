package slang_vm

import (
	"bytes"
	"os"
	"testing"
)

func TestLoader(t *testing.T) {
	// Fixture compiled from:
	//   local x = 42
	//   local s = "hello"
	//   local b = true
	//   local f = 3.14
	f, err := os.Open("testdata/loader_test.slb")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	proto, err := LoadPrototype(f)
	if err != nil {
		t.Fatalf("LoadPrototype: %v", err)
	}

	if len(proto.Instructions) == 0 {
		t.Error("expected non-empty instruction list")
	}
	if proto.MaxVarStackSize <= 0 {
		t.Errorf("expected MaxVarStackSize > 0, got %d", proto.MaxVarStackSize)
	}
	if proto.Nargs != 0 {
		t.Errorf("expected Nargs=0, got %d", proto.Nargs)
	}
	if proto.IsVarArg {
		t.Error("expected IsVarArg=false")
	}

	// Verify constants: 42 (int), "hello" (string), 3.14 (double)
	// Note: `true` is emitted as a loadBool instruction, not a constant.
	foundInt := false
	foundString := false
	foundFloat := false
	for _, c := range proto.Constants {
		switch c.Type {
		case TypeInt:
			if c.IVal == 42 {
				foundInt = true
			}
		case TypeString:
			if c.Obj.(string) == "hello" {
				foundString = true
			}
		case TypeFloat:
			if c.FVal > 3.13 && c.FVal < 3.15 {
				foundFloat = true
			}
		}
	}
	if !foundInt {
		t.Error("expected constant int 42")
	}
	if !foundString {
		t.Error("expected constant string \"hello\"")
	}
	if !foundFloat {
		t.Error("expected constant float ~3.14")
	}
}

func TestLoaderBadMagic(t *testing.T) {
	data := []byte{0x00, 0x01, 0x02, 0x03, 0x04}
	_, err := LoadPrototype(bytes.NewReader(data))
	if err == nil {
		t.Error("expected error for bad magic header")
	}
}

