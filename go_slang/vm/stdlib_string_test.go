package slang_vm

import "testing"

func TestStringModule(t *testing.T) {
	m := buildStringModule()

	t.Run("join_basic", func(t *testing.T) {
		tbl := NewSlangTable()
		tbl.Append(StringVal("a"))
		tbl.Append(StringVal("b"))
		tbl.Append(StringVal("c"))
		got := callModuleFn(t, m, "join", TableVal(tbl), StringVal(", "))
		if got.Obj.(string) != "a, b, c" {
			t.Errorf("join = %q, want %q", got.Obj.(string), "a, b, c")
		}
	})

	t.Run("join_default_sep", func(t *testing.T) {
		tbl := NewSlangTable()
		tbl.Append(StringVal("x"))
		tbl.Append(StringVal("y"))
		got := callModuleFn(t, m, "join", TableVal(tbl))
		if got.Obj.(string) != "x y" {
			t.Errorf("join default sep = %q, want %q", got.Obj.(string), "x y")
		}
	})

	t.Run("join_empty_table", func(t *testing.T) {
		tbl := NewSlangTable()
		got := callModuleFn(t, m, "join", TableVal(tbl), StringVal(","))
		if got.Obj.(string) != "" {
			t.Errorf("join empty = %q, want %q", got.Obj.(string), "")
		}
	})

	t.Run("substring_basic", func(t *testing.T) {
		got := callModuleFn(t, m, "substring", StringVal("hello"), IntVal(1), IntVal(3))
		if got.Obj.(string) != "el" {
			t.Errorf("substring = %q, want %q", got.Obj.(string), "el")
		}
	})

	t.Run("substring_unicode", func(t *testing.T) {
		// "héllo" — é is a multi-byte rune
		got := callModuleFn(t, m, "substring", StringVal("héllo"), IntVal(0), IntVal(2))
		if got.Obj.(string) != "hé" {
			t.Errorf("substring unicode = %q, want %q", got.Obj.(string), "hé")
		}
	})

	t.Run("substring_no_end", func(t *testing.T) {
		got := callModuleFn(t, m, "substring", StringVal("hello"), IntVal(2))
		if got.Obj.(string) != "llo" {
			t.Errorf("substring no end = %q, want %q", got.Obj.(string), "llo")
		}
	})

	t.Run("substring_clamp", func(t *testing.T) {
		// start > len → empty string
		got := callModuleFn(t, m, "substring", StringVal("hi"), IntVal(100), IntVal(200))
		if got.Obj.(string) != "" {
			t.Errorf("substring clamp = %q, want %q", got.Obj.(string), "")
		}
	})
}
