package slang_vm

// tableKey converts a Value into a Go-comparable map key.
// This avoids using Value directly as a map key (Obj interface{} could hold non-comparable types).
func tableKey(v Value) interface{} {
	switch v.Type {
	case TypeNil:
		return nil
	case TypeBool:
		return v.IVal != 0
	case TypeInt:
		return v.IVal
	case TypeFloat:
		return v.FVal
	case TypeString:
		return v.Obj.(string)
	default:
		// Pointer types (*SlangTable, *Closure, *Userdata, *VM) are comparable.
		return v.Obj
	}
}

type SlangTable struct {
	list []Value
	hash map[interface{}]Value
	Meta *SlangTable
}

func NewSlangTable() *SlangTable {
	return &SlangTable{
		hash: make(map[interface{}]Value),
	}
}

func (t *SlangTable) Get(key Value) Value {
	if key.Type == TypeInt {
		idx := int(key.IVal)
		if idx >= 0 && idx < len(t.list) {
			return t.list[idx]
		}
	}
	if key.Type == TypeString && key.Obj.(string) == "meta" {
		if t.Meta != nil {
			return TableVal(t.Meta)
		}
		return NilVal()
	}
	v, ok := t.hash[tableKey(key)]
	if !ok {
		return NilVal()
	}
	return v
}

func (t *SlangTable) Set(key Value, val Value) {
	if key.Type == TypeString && key.Obj.(string) == "meta" {
		if val.Type == TypeTable {
			t.Meta = val.Obj.(*SlangTable)
		} else if val.Type == TypeNil {
			t.Meta = nil
		}
		return
	}
	if key.Type == TypeInt {
		idx := int(key.IVal)
		if idx >= 0 && idx < len(t.list) {
			t.list[idx] = val
			return
		}
		if idx == len(t.list) {
			t.list = append(t.list, val)
			t.fixList()
			return
		}
	}
	k := tableKey(key)
	if val.Type == TypeNil {
		delete(t.hash, k)
	} else {
		t.hash[k] = val
	}
	t.fixList()
}

func (t *SlangTable) Append(val Value) {
	t.list = append(t.list, val)
	t.fixList()
}

// fixList promotes consecutive integer keys from hash into the list.
func (t *SlangTable) fixList() {
	for {
		k := int64(len(t.list))
		if v, ok := t.hash[k]; ok {
			t.list = append(t.list, v)
			delete(t.hash, k)
		} else {
			break
		}
	}
}

func (t *SlangTable) Length() int {
	return len(t.list)
}
