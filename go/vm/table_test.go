package vm

import (
	"fmt"
	"testing"
)

func TestTableSetStrNullRemoves(t *testing.T) {
	tb := NewTable(0, 0)
	tb.SetStr("a", Int(1))
	tb.SetStr("b", Int(2))
	tb.SetStr("a", Null)
	if tb.Len() != 1 {
		t.Fatalf("len = %d, want 1", tb.Len())
	}
	for _, k := range tb.Keys() {
		if tb.Get(k).IsNull() {
			t.Fatalf("key %v has no value", k)
		}
	}
	if !tb.GetStr("a").IsNull() {
		t.Fatal("a should be gone")
	}
}

func TestTableKeysStayConsistentUnderChurn(t *testing.T) {
	tb := NewTable(0, 0)
	for round := 0; round < 5; round++ {
		for i := 0; i < 40; i++ {
			tb.Set(String(fmt.Sprintf("k%d", i)), Int(int64(i+round)))
		}
		for i := 0; i < 30; i++ {
			tb.Set(String(fmt.Sprintf("k%d", i)), Null)
		}
		for _, k := range tb.Keys() {
			if tb.Get(k).IsNull() {
				t.Fatalf("round %d: key %v has no value", round, k)
			}
		}
		if tb.Len() != 10 {
			t.Fatalf("round %d: len = %d, want 10", round, tb.Len())
		}
	}
}

func TestTableArrayAndHashSemantics(t *testing.T) {
	tb := NewTable(0, 0)
	tb.Set(Int(0), String("a"))
	tb.Set(Int(1), String("b"))
	tb.Set(Int(3), String("d")) // gap: goes to the hash part
	if tb.ArrayLen() != 2 || tb.Len() != 3 {
		t.Fatalf("array=%d len=%d", tb.ArrayLen(), tb.Len())
	}
	tb.Set(Int(2), String("c")) // fills the gap and migrates 3 into the array
	if tb.ArrayLen() != 4 {
		t.Fatalf("array=%d after fixList, want 4", tb.ArrayLen())
	}
	if v := tb.Remove(Int(0)); v.AsString() != "a" || tb.ArrayLen() != 3 || tb.GetInt(0).AsString() != "b" {
		t.Fatalf("remove should shift the array part")
	}
	tb.Set(Float(1.0), String("x")) // integral floats normalise to int keys
	if tb.GetInt(1).AsString() != "x" {
		t.Fatal("float key 1.0 should address index 1")
	}
	meta := NewTable(0, 0)
	tb.Set(String("meta"), TableValue(meta))
	if tb.Meta != meta || tb.GetStr("meta").AsTable() != meta {
		t.Fatal("meta key should address the metatable")
	}
	if tb.Len() != 3 {
		t.Fatalf("meta must not count as an entry, len=%d", tb.Len())
	}
}

func TestTableEqualsIsStructural(t *testing.T) {
	a := NewTableFrom(Int(1), String("x"))
	a.SetStr("k", TableValue(NewTableFrom(Int(2))))
	b := NewTableFrom(Int(1), String("x"))
	b.SetStr("k", TableValue(NewTableFrom(Int(2))))
	if !Equals(TableValue(a), TableValue(b)) {
		t.Fatal("structurally equal tables should be ==")
	}
	b.SetStr("k", TableValue(NewTableFrom(Int(3))))
	if Equals(TableValue(a), TableValue(b)) {
		t.Fatal("different nested values should not be ==")
	}
}

func TestFormatFloatFollowsDart(t *testing.T) {
	cases := map[float64]string{
		1:                       "1.0",
		0.5:                     "0.5",
		-2.25:                   "-2.25",
		100:                     "100.0",
		1e21:                    "1e+21",
		1e-7:                    "1e-7",
		0.000001:                "0.000001",
		123456789012345680000.0: "123456789012345680000.0",
	}
	for f, want := range cases {
		if got := formatFloat(f); got != want {
			t.Errorf("formatFloat(%v) = %q, want %q", f, got, want)
		}
	}
}

func TestBytecodeRoundTrip(t *testing.T) {
	p := &FunctionProto{
		Code:     []uint32{1, 2, 3},
		Consts:   []Value{Int(-5), Float(1.5), String("héllo"), True, Null},
		Upvals:   []UpvalDesc{{Name: "_ENV", Index: 0, IsLocal: true}},
		Locs:     []LocInfo{{FirstPC: 0, Origin: "x", Line: 1, Column: 2}},
		MaxStack: 3,
		NArgs:    1,
		IsVarArg: true,
		Children: []*FunctionProto{{Code: []uint32{16}}},
	}
	q, err := Decode(Encode(p, false))
	if err != nil {
		t.Fatal(err)
	}
	if len(q.Code) != 3 || len(q.Consts) != 5 || q.Consts[0].AsInt() != -5 || q.Consts[2].AsString() != "héllo" ||
		!q.Consts[4].IsNull() || !q.IsVarArg || q.NArgs != 1 || q.MaxStack != 3 || len(q.Children) != 1 ||
		q.Upvals[0].Name != "_ENV" || q.Locs[0].Column != 2 {
		t.Fatalf("round trip mismatch: %+v", q)
	}
}
