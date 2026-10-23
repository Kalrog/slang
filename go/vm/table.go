package vm

import (
	"math"
	"strconv"
	"strings"
)

type tentry struct {
	key Value
	val Value
}

// Table is the slang table: an array part for keys 0..n-1 plus an
// insertion-ordered hash part. The key "meta" addresses the metatable.
type Table struct {
	arr  []Value
	ents []tentry
	smap map[string]int32
	amap map[Value]int32
	dead int
	Meta *Table
}

func NewTable(narr, nhash int) *Table {
	t := &Table{}
	if narr > 0 {
		t.arr = make([]Value, 0, narr)
	}
	if nhash > 0 {
		t.ents = make([]tentry, 0, nhash)
	}
	return t
}

// NewTableFrom builds a table whose array part holds the given values.
func NewTableFrom(values ...Value) *Table {
	t := &Table{arr: make([]Value, 0, len(values))}
	for _, v := range values {
		t.Append(v)
	}
	return t
}

func normKey(k Value) Value {
	if k.k == KFloat {
		f := k.AsFloat()
		if f == math.Trunc(f) && f >= -9.2e18 && f <= 9.2e18 {
			return Int(int64(f))
		}
	}
	return k
}

// Get is the raw lookup (no metamethods).
func (t *Table) Get(key Value) Value {
	switch key.k {
	case KInt:
		if i := key.n; i >= 0 && i < int64(len(t.arr)) {
			return t.arr[i]
		}
		return t.anyGet(key)
	case KString:
		return t.GetStr(key.o.(string))
	case KFloat:
		key = normKey(key)
		if key.k == KInt {
			return t.Get(key)
		}
		return t.anyGet(key)
	case KNull:
		return Null
	default:
		return t.anyGet(key)
	}
}

func (t *Table) GetStr(s string) Value {
	if t.smap != nil {
		if idx, ok := t.smap[s]; ok {
			return t.ents[idx].val
		}
	}
	if s == "meta" {
		return TableValue(t.Meta)
	}
	return Null
}

func (t *Table) GetInt(i int64) Value {
	if i >= 0 && i < int64(len(t.arr)) {
		return t.arr[i]
	}
	return t.anyGet(Int(i))
}

func (t *Table) anyGet(key Value) Value {
	if t.amap != nil {
		if idx, ok := t.amap[key]; ok {
			return t.ents[idx].val
		}
	}
	return Null
}

// Set is the raw store. Storing null removes the key (and shifts the array
// part when the key is an array index), as the Dart implementation did.
func (t *Table) Set(key, val Value) {
	if val.k == KNull {
		t.Remove(key)
		return
	}
	switch key.k {
	case KInt:
		t.setInt(key.n, val)
	case KString:
		t.SetStr(key.o.(string), val)
	case KFloat:
		key = normKey(key)
		if key.k == KInt {
			t.setInt(key.n, val)
		} else {
			t.setAny(key, val)
		}
	case KNull:
		return
	default:
		t.setAny(key, val)
	}
}

func (t *Table) setInt(i int64, val Value) {
	n := int64(len(t.arr))
	switch {
	case i >= 0 && i < n:
		t.arr[i] = val
	case i == n:
		t.arr = append(t.arr, val)
		t.fixList()
	default:
		t.setAny(Int(i), val)
	}
}

func (t *Table) SetStr(s string, val Value) {
	if val.k == KNull {
		t.Remove(String(s))
		return
	}
	if s == "meta" {
		switch val.k {
		case KTable:
			t.Meta = val.o.(*Table)
		case KNull:
			t.Meta = nil
		}
		return
	}
	if t.smap == nil {
		t.smap = make(map[string]int32)
	} else if idx, ok := t.smap[s]; ok {
		t.ents[idx].val = val
		return
	}
	t.smap[s] = int32(len(t.ents))
	t.ents = append(t.ents, tentry{String(s), val})
}

func (t *Table) setAny(key, val Value) {
	if t.amap == nil {
		t.amap = make(map[Value]int32)
	} else if idx, ok := t.amap[key]; ok {
		t.ents[idx].val = val
		return
	}
	t.amap[key] = int32(len(t.ents))
	t.ents = append(t.ents, tentry{key, val})
}

// fixList migrates hash entries whose integer key continues the array part.
func (t *Table) fixList() {
	for t.amap != nil {
		k := Int(int64(len(t.arr)))
		idx, ok := t.amap[k]
		if !ok {
			return
		}
		v := t.ents[idx].val
		delete(t.amap, k)
		t.killEntry(idx)
		t.arr = append(t.arr, v)
	}
}

func (t *Table) killEntry(idx int32) {
	t.ents[idx] = tentry{}
	t.dead++
	if t.dead > 8 && t.dead > len(t.ents)/2 {
		t.compact()
	}
}

func (t *Table) compact() {
	live := make([]tentry, 0, len(t.ents)-t.dead)
	for _, e := range t.ents {
		if e.key.k != KNull {
			live = append(live, e)
		}
	}
	t.ents = live
	t.dead = 0
	t.smap = nil
	t.amap = nil
	for i, e := range t.ents {
		if e.key.k == KString {
			if t.smap == nil {
				t.smap = make(map[string]int32)
			}
			t.smap[e.key.o.(string)] = int32(i)
		} else {
			if t.amap == nil {
				t.amap = make(map[Value]int32)
			}
			t.amap[e.key] = int32(i)
		}
	}
}

// Remove deletes a key and returns the removed value (null if absent).
func (t *Table) Remove(key Value) Value {
	switch key.k {
	case KInt:
		i := key.n
		if i >= 0 && i < int64(len(t.arr)) {
			v := t.arr[i]
			copy(t.arr[i:], t.arr[i+1:])
			t.arr[len(t.arr)-1] = Null
			t.arr = t.arr[:len(t.arr)-1]
			return v
		}
		return t.removeAny(key)
	case KString:
		s := key.o.(string)
		if t.smap != nil {
			if idx, ok := t.smap[s]; ok {
				v := t.ents[idx].val
				delete(t.smap, s)
				t.killEntry(idx)
				return v
			}
		}
		if s == "meta" {
			m := t.Meta
			t.Meta = nil
			return TableValue(m)
		}
		return Null
	case KFloat:
		key = normKey(key)
		if key.k == KInt {
			return t.Remove(key)
		}
		return t.removeAny(key)
	case KNull:
		return Null
	default:
		return t.removeAny(key)
	}
}

func (t *Table) removeAny(key Value) Value {
	if t.amap != nil {
		if idx, ok := t.amap[key]; ok {
			v := t.ents[idx].val
			delete(t.amap, key)
			t.killEntry(idx)
			return v
		}
	}
	return Null
}

// Len is the number of entries (array part plus hash part).
func (t *Table) Len() int { return len(t.arr) + len(t.ents) - t.dead }

// ArrayLen is the length of the array part only.
func (t *Table) ArrayLen() int { return len(t.arr) }

// Append adds a value at the end of the array part.
func (t *Table) Append(v Value) {
	if v.k == KNull {
		return
	}
	t.arr = append(t.arr, v)
	t.fixList()
}

// PushSlot appends v to the array part even when it is null (sequence results
// of the parser library need positional null entries).
func (t *Table) PushSlot(v Value) {
	t.arr = append(t.arr, v)
	t.fixList()
}

// AddAll merges another table: array parts are concatenated, hash entries copied.
func (t *Table) AddAll(o *Table) {
	t.arr = append(t.arr, o.arr...)
	for _, e := range o.ents {
		if e.key.k == KNull {
			continue
		}
		t.Set(e.key, e.val)
	}
	t.fixList()
}

// Keys returns array indices followed by hash keys in insertion order.
func (t *Table) Keys() []Value {
	keys := make([]Value, 0, t.Len())
	for i := range t.arr {
		keys = append(keys, Int(int64(i)))
	}
	for _, e := range t.ents {
		if e.key.k != KNull {
			keys = append(keys, e.key)
		}
	}
	return keys
}

// Values returns the array values followed by hash values in insertion order.
func (t *Table) Values() []Value {
	vals := make([]Value, 0, t.Len())
	vals = append(vals, t.arr...)
	for _, e := range t.ents {
		if e.key.k != KNull {
			vals = append(vals, e.val)
		}
	}
	return vals
}

// Range calls fn for every entry in iteration order until it returns false.
func (t *Table) Range(fn func(key, val Value) bool) {
	for i, v := range t.arr {
		if !fn(Int(int64(i)), v) {
			return
		}
	}
	for _, e := range t.ents {
		if e.key.k == KNull {
			continue
		}
		if !fn(e.key, e.val) {
			return
		}
	}
}

// Equals is structural equality (metatables are not compared).
func (t *Table) Equals(o *Table) bool {
	if t == o {
		return true
	}
	if len(t.arr) != len(o.arr) || t.Len() != o.Len() {
		return false
	}
	for i := range t.arr {
		if !Equals(t.arr[i], o.arr[i]) {
			return false
		}
	}
	for _, e := range t.ents {
		if e.key.k == KNull {
			continue
		}
		if !Equals(o.Get(e.key), e.val) {
			return false
		}
	}
	return true
}

func (t *Table) String() string {
	var sb strings.Builder
	t.writeTo(&sb, 0)
	return sb.String()
}

func (t *Table) writeTo(sb *strings.Builder, depth int) {
	if t.Meta != nil {
		if ty := t.Meta.GetStr("__type"); ty.k == KString {
			sb.WriteByte('\'')
			sb.WriteString(ty.o.(string))
		}
	}
	if depth > 32 {
		sb.WriteString("{...}")
		return
	}
	sb.WriteByte('{')
	for i, v := range t.arr {
		sb.WriteString(strconv.Itoa(i))
		sb.WriteString(": ")
		writeValue(sb, v, depth+1)
		sb.WriteString(", ")
	}
	for _, e := range t.ents {
		if e.key.k == KNull {
			continue
		}
		writeValue(sb, e.key, depth+1)
		sb.WriteString(": ")
		writeValue(sb, e.val, depth+1)
		sb.WriteString(", ")
	}
	sb.WriteByte('}')
}

func writeValue(sb *strings.Builder, v Value, depth int) {
	if v.k == KTable {
		v.o.(*Table).writeTo(sb, depth)
		return
	}
	sb.WriteString(v.String())
}
