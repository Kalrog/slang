package vm

import (
	"fmt"
	"strings"
)

type opMode uint8

const (
	modeABC opMode = iota
	modeABx
	modeAsBx
	modeAx
	modeNone
)

var opModes = [...]opMode{
	modeABx, modeABC, modeAx, modeNone, modeNone, modeNone, modeNone, modeNone,
	modeNone, modeNone, modeNone, modeNone, modeNone, modeAsBx, modeAsBx, modeABx,
	modeNone, modeABC, modeNone, modeNone, modeAx, modeAx, modeAx, modeABC,
	modeAsBx, modeABx, modeNone, modeNone,
}

// InstructionString renders one instruction.
func InstructionString(ins uint32) string {
	op := ins & 0x3F
	if int(op) >= len(opModes) {
		return fmt.Sprintf("op%d", op)
	}
	name := opNames[op]
	a := (ins >> 6) & 0xFF
	b := (ins >> 23) & 0x1FF
	c := (ins >> 14) & 0x1FF
	bx := ins >> 14
	switch opModes[op] {
	case modeABC:
		return fmt.Sprintf("%s A=%d B=%d C=%d", name, a, b, c)
	case modeABx:
		return fmt.Sprintf("%s A=%d Bx=%d", name, a, bx)
	case modeAsBx:
		return fmt.Sprintf("%s A=%d sBx=%d", name, a, int(bx)-0x1FFFF)
	case modeAx:
		return fmt.Sprintf("%s Ax=%d", name, ins>>6)
	default:
		return name
	}
}

// Disassemble renders a prototype and its children.
func Disassemble(p *FunctionProto) string {
	var sb strings.Builder
	disasm(&sb, p, "")
	return sb.String()
}

func disasm(sb *strings.Builder, p *FunctionProto, indent string) {
	fmt.Fprintf(sb, "%sfunction (nargs=%d vararg=%v maxstack=%d)\n", indent, p.NArgs, p.IsVarArg, p.MaxStack)
	fmt.Fprintf(sb, "%sInstructions:\n", indent)
	for i, ins := range p.Code {
		loc := ""
		for _, l := range p.Locs {
			if l.FirstPC == i {
				loc = fmt.Sprintf("  %s:%d:%d", l.Origin, l.Line, l.Column)
				break
			}
		}
		fmt.Fprintf(sb, "%s  %4d: %s%s\n", indent, i, InstructionString(ins), loc)
	}
	if len(p.Consts) > 0 {
		fmt.Fprintf(sb, "%sConstants:\n", indent)
		for i, c := range p.Consts {
			if c.k == KString {
				fmt.Fprintf(sb, "%s  %d: %q\n", indent, i, c.o.(string))
			} else {
				fmt.Fprintf(sb, "%s  %d: %s\n", indent, i, c.String())
			}
		}
	}
	if len(p.Upvals) > 0 {
		fmt.Fprintf(sb, "%sUpvalues:\n", indent)
		for i, u := range p.Upvals {
			fmt.Fprintf(sb, "%s  %d: %s index=%d local=%v\n", indent, i, u.Name, u.Index, u.IsLocal)
		}
	}
	if len(p.Children) > 0 {
		fmt.Fprintf(sb, "%sChildren:\n", indent)
		for i, c := range p.Children {
			fmt.Fprintf(sb, "%s  %d:\n", indent, i)
			disasm(sb, c, indent+"    ")
		}
	}
}
