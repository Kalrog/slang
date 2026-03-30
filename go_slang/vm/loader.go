package slang_vm

import (
	"encoding/binary"
	"fmt"
	"io"
	"math"
)

var slangMagic = [5]byte{0x53, 0x4C, 0x41, 0x4E, 0x47}

// TypeMarker constants match Dart's TypeMarker enum (zero-indexed):
// integer=0, double=1, string=2, boolean=3, nullType=4
const (
	tmInteger = 0
	tmDouble  = 1
	tmString  = 2
	tmBoolean = 3
	tmNull    = 4
)

// LoadPrototype reads a .slb binary and returns the root FunctionPrototype.
func LoadPrototype(r io.Reader) (*FunctionPrototype, error) {
	lr := &slbReader{r: r}

	var magic [5]byte
	if err := lr.readFull(magic[:]); err != nil {
		return nil, fmt.Errorf("slb: read magic: %w", err)
	}
	if magic != slangMagic {
		return nil, fmt.Errorf("slb: invalid magic header")
	}

	return lr.readPrototype()
}

type slbReader struct {
	r   io.Reader
	buf [8]byte
}

func (r *slbReader) readFull(p []byte) error {
	_, err := io.ReadFull(r.r, p)
	return err
}

func (r *slbReader) readByte() (byte, error) {
	if err := r.readFull(r.buf[:1]); err != nil {
		return 0, err
	}
	return r.buf[0], nil
}

// readInt32 reads a little-endian int32 (Dart's writeInt format).
func (r *slbReader) readInt32() (int32, error) {
	if err := r.readFull(r.buf[:4]); err != nil {
		return 0, err
	}
	return int32(binary.LittleEndian.Uint32(r.buf[:4])), nil
}

// readUint32 reads a little-endian uint32 (for instructions).
func (r *slbReader) readUint32() (uint32, error) {
	if err := r.readFull(r.buf[:4]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(r.buf[:4]), nil
}

// readFloat64 reads a little-endian float64 (Dart's writeDouble format).
func (r *slbReader) readFloat64() (float64, error) {
	if err := r.readFull(r.buf[:8]); err != nil {
		return 0, err
	}
	bits := binary.LittleEndian.Uint64(r.buf[:8])
	return math.Float64frombits(bits), nil
}

// readBool reads a single byte: 0=false, 1=true.
func (r *slbReader) readBool() (bool, error) {
	b, err := r.readByte()
	return b == 1, err
}

// readString reads a length-prefixed string.
// Format: 1-byte length (or 0xFF + 4-byte length for strings > 254 bytes) + raw bytes.
// Dart writes codeUnits which are ASCII/Latin-1 compatible for typical identifiers.
func (r *slbReader) readString() (string, error) {
	lenByte, err := r.readByte()
	if err != nil {
		return "", err
	}
	var length int
	if lenByte == 0xFF {
		n, err := r.readInt32()
		if err != nil {
			return "", err
		}
		length = int(n)
	} else {
		length = int(lenByte)
	}
	if length == 0 {
		return "", nil
	}
	buf := make([]byte, length)
	if err := r.readFull(buf); err != nil {
		return "", err
	}
	return string(buf), nil
}

func (r *slbReader) readPrototype() (*FunctionPrototype, error) {
	maxVarStackSize, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("maxVarStackSize: %w", err)
	}

	nargs, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("nargs: %w", err)
	}

	isVarArg, err := r.readBool()
	if err != nil {
		return nil, fmt.Errorf("isVarArg: %w", err)
	}

	nInstructions, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("nInstructions: %w", err)
	}
	instructions := make([]uint32, nInstructions)
	for i := range instructions {
		instructions[i], err = r.readUint32()
		if err != nil {
			return nil, fmt.Errorf("instruction[%d]: %w", i, err)
		}
	}

	nSourceLocations, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("nSourceLocations: %w", err)
	}
	sourceLocations := make([]SourceLocationInfo, nSourceLocations)
	for i := range sourceLocations {
		sl, err := r.readSourceLocation()
		if err != nil {
			return nil, fmt.Errorf("sourceLocation[%d]: %w", i, err)
		}
		sourceLocations[i] = sl
	}

	nConstants, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("nConstants: %w", err)
	}
	constants := make([]Value, nConstants)
	for i := range constants {
		constants[i], err = r.readConstant()
		if err != nil {
			return nil, fmt.Errorf("constant[%d]: %w", i, err)
		}
	}

	nUpvalues, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("nUpvalues: %w", err)
	}
	upvalues := make([]UpvalueDef, nUpvalues)
	for i := range upvalues {
		upvalues[i], err = r.readUpvalue()
		if err != nil {
			return nil, fmt.Errorf("upvalue[%d]: %w", i, err)
		}
	}

	nChildren, err := r.readInt32()
	if err != nil {
		return nil, fmt.Errorf("nChildren: %w", err)
	}
	children := make([]*FunctionPrototype, nChildren)
	for i := range children {
		children[i], err = r.readPrototype()
		if err != nil {
			return nil, fmt.Errorf("child[%d]: %w", i, err)
		}
	}

	return &FunctionPrototype{
		MaxVarStackSize: int(maxVarStackSize),
		Nargs:           int(nargs),
		IsVarArg:        isVarArg,
		Instructions:    instructions,
		SourceLocations: sourceLocations,
		Constants:       constants,
		Upvalues:        upvalues,
		Children:        children,
	}, nil
}

func (r *slbReader) readSourceLocation() (SourceLocationInfo, error) {
	firstInstruction, err := r.readInt32()
	if err != nil {
		return SourceLocationInfo{}, err
	}
	origin, err := r.readString()
	if err != nil {
		return SourceLocationInfo{}, err
	}
	line, err := r.readInt32()
	if err != nil {
		return SourceLocationInfo{}, err
	}
	col, err := r.readInt32()
	if err != nil {
		return SourceLocationInfo{}, err
	}
	return SourceLocationInfo{
		FirstInstruction: int(firstInstruction),
		Origin:           origin,
		Line:             int(line),
		Col:              int(col),
	}, nil
}

func (r *slbReader) readConstant() (Value, error) {
	marker, err := r.readByte()
	if err != nil {
		return NilVal(), err
	}
	switch int(marker) {
	case tmInteger:
		n, err := r.readInt32()
		if err != nil {
			return NilVal(), err
		}
		return IntVal(int64(n)), nil
	case tmDouble:
		f, err := r.readFloat64()
		if err != nil {
			return NilVal(), err
		}
		return FloatVal(f), nil
	case tmString:
		s, err := r.readString()
		if err != nil {
			return NilVal(), err
		}
		return StringVal(s), nil
	case tmBoolean:
		b, err := r.readBool()
		if err != nil {
			return NilVal(), err
		}
		return BoolVal(b), nil
	case tmNull:
		return NilVal(), nil
	default:
		return NilVal(), fmt.Errorf("unknown constant type marker: %d", marker)
	}
}

func (r *slbReader) readUpvalue() (UpvalueDef, error) {
	name, err := r.readString()
	if err != nil {
		return UpvalueDef{}, err
	}
	index, err := r.readInt32()
	if err != nil {
		return UpvalueDef{}, err
	}
	isLocal, err := r.readBool()
	if err != nil {
		return UpvalueDef{}, err
	}
	return UpvalueDef{Name: name, Index: int(index), IsLocal: isLocal}, nil
}
