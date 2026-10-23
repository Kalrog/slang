package vm

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// .slb container, version 2:
//
//	magic "SLANG", u8 version
//	proto := u32 maxStack, u32 nargs, u8 isVarArg,
//	         u32 nCode, u32[nCode],
//	         u32 nLocs, {u32 firstPC, str origin, u32 line, u32 column}*,
//	         u32 nConsts, {u8 tag, payload}*   (0 int i64, 1 double f64, 2 string, 3 bool u8, 4 null)
//	         u32 nUpvals, {str name, u32 index, u8 isLocal}*,
//	         u32 nChildren, proto*
//	str := u32 byteLen, bytes (UTF-8)
//
// Everything is little endian.

var slbMagic = []byte("SLANG")

const SlbVersion = 2

const (
	tagInt = iota
	tagDouble
	tagString
	tagBool
	tagNull
)

// Encode serialises a prototype. With stripLocs the source locations are omitted.
func Encode(p *FunctionProto, stripLocs bool) []byte {
	w := &bcWriter{}
	w.bytes(slbMagic)
	w.u8(SlbVersion)
	w.proto(p, stripLocs)
	return w.buf
}

type bcWriter struct{ buf []byte }

func (w *bcWriter) bytes(b []byte) { w.buf = append(w.buf, b...) }
func (w *bcWriter) u8(v uint8)     { w.buf = append(w.buf, v) }
func (w *bcWriter) u32(v uint32)   { w.buf = binary.LittleEndian.AppendUint32(w.buf, v) }
func (w *bcWriter) i64(v int64)    { w.buf = binary.LittleEndian.AppendUint64(w.buf, uint64(v)) }
func (w *bcWriter) f64(v float64) {
	w.buf = binary.LittleEndian.AppendUint64(w.buf, math.Float64bits(v))
}
func (w *bcWriter) str(s string) {
	w.u32(uint32(len(s)))
	w.buf = append(w.buf, s...)
}

func (w *bcWriter) proto(p *FunctionProto, stripLocs bool) {
	w.u32(uint32(p.MaxStack))
	w.u32(uint32(p.NArgs))
	if p.IsVarArg {
		w.u8(1)
	} else {
		w.u8(0)
	}
	w.u32(uint32(len(p.Code)))
	for _, c := range p.Code {
		w.u32(c)
	}
	if stripLocs {
		w.u32(0)
	} else {
		w.u32(uint32(len(p.Locs)))
		for _, l := range p.Locs {
			w.u32(uint32(l.FirstPC))
			w.str(l.Origin)
			w.u32(uint32(l.Line))
			w.u32(uint32(l.Column))
		}
	}
	w.u32(uint32(len(p.Consts)))
	for _, c := range p.Consts {
		switch c.k {
		case KInt:
			w.u8(tagInt)
			w.i64(c.n)
		case KFloat:
			w.u8(tagDouble)
			w.f64(c.AsFloat())
		case KString:
			w.u8(tagString)
			w.str(c.o.(string))
		case KBool:
			w.u8(tagBool)
			w.u8(uint8(c.n))
		default:
			w.u8(tagNull)
		}
	}
	w.u32(uint32(len(p.Upvals)))
	for _, u := range p.Upvals {
		w.str(u.Name)
		w.u32(uint32(u.Index))
		if u.IsLocal {
			w.u8(1)
		} else {
			w.u8(0)
		}
	}
	w.u32(uint32(len(p.Children)))
	for _, c := range p.Children {
		w.proto(c, stripLocs)
	}
}

// Decode parses a .slb v2 container.
func Decode(data []byte) (*FunctionProto, error) {
	r := &bcReader{buf: data}
	magic := r.take(len(slbMagic))
	if r.err != nil || string(magic) != string(slbMagic) {
		return nil, errors.New("not a slang bytecode file (bad magic)")
	}
	if v := r.u8(); v != SlbVersion {
		return nil, fmt.Errorf("unsupported bytecode version %d (want %d)", v, SlbVersion)
	}
	p := r.proto(0)
	if r.err != nil {
		return nil, r.err
	}
	return p, nil
}

type bcReader struct {
	buf []byte
	pos int
	err error
}

func (r *bcReader) fail(msg string) {
	if r.err == nil {
		r.err = errors.New("bytecode: " + msg)
	}
}

func (r *bcReader) take(n int) []byte {
	if r.err != nil {
		return nil
	}
	if n < 0 || r.pos+n > len(r.buf) {
		r.fail("unexpected end of data")
		return nil
	}
	b := r.buf[r.pos : r.pos+n]
	r.pos += n
	return b
}

func (r *bcReader) u8() uint8 {
	b := r.take(1)
	if b == nil {
		return 0
	}
	return b[0]
}

func (r *bcReader) u32() uint32 {
	b := r.take(4)
	if b == nil {
		return 0
	}
	return binary.LittleEndian.Uint32(b)
}

func (r *bcReader) i64() int64 {
	b := r.take(8)
	if b == nil {
		return 0
	}
	return int64(binary.LittleEndian.Uint64(b))
}

func (r *bcReader) f64() float64 {
	b := r.take(8)
	if b == nil {
		return 0
	}
	return math.Float64frombits(binary.LittleEndian.Uint64(b))
}

func (r *bcReader) str() string {
	n := r.u32()
	b := r.take(int(n))
	if b == nil {
		return ""
	}
	return string(b)
}

func (r *bcReader) count(what string) int {
	n := int(r.u32())
	if r.err == nil && n > len(r.buf) {
		r.fail("implausible " + what + " count")
		return 0
	}
	return n
}

func (r *bcReader) proto(depth int) *FunctionProto {
	if depth > 200 {
		r.fail("prototype nesting too deep")
		return nil
	}
	p := &FunctionProto{}
	p.MaxStack = int(r.u32())
	p.NArgs = int(r.u32())
	p.IsVarArg = r.u8() != 0
	n := r.count("instruction")
	if r.err != nil {
		return nil
	}
	p.Code = make([]uint32, n)
	for i := range p.Code {
		p.Code[i] = r.u32()
	}
	n = r.count("location")
	if r.err != nil {
		return nil
	}
	p.Locs = make([]LocInfo, n)
	for i := range p.Locs {
		p.Locs[i].FirstPC = int(r.u32())
		p.Locs[i].Origin = r.str()
		p.Locs[i].Line = int(r.u32())
		p.Locs[i].Column = int(r.u32())
	}
	n = r.count("constant")
	if r.err != nil {
		return nil
	}
	p.Consts = make([]Value, n)
	for i := range p.Consts {
		switch r.u8() {
		case tagInt:
			p.Consts[i] = Int(r.i64())
		case tagDouble:
			p.Consts[i] = Float(r.f64())
		case tagString:
			p.Consts[i] = String(r.str())
		case tagBool:
			p.Consts[i] = Bool(r.u8() != 0)
		case tagNull:
			p.Consts[i] = Null
		default:
			r.fail("unknown constant tag")
			return nil
		}
	}
	n = r.count("upvalue")
	if r.err != nil {
		return nil
	}
	p.Upvals = make([]UpvalDesc, n)
	for i := range p.Upvals {
		p.Upvals[i].Name = r.str()
		p.Upvals[i].Index = int(r.u32())
		p.Upvals[i].IsLocal = r.u8() != 0
	}
	n = r.count("child")
	if r.err != nil {
		return nil
	}
	p.Children = make([]*FunctionProto, n)
	for i := range p.Children {
		p.Children[i] = r.proto(depth + 1)
		if r.err != nil {
			return nil
		}
	}
	return p
}
