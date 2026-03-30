package slang_vm

/// Bytecode Layout:
///  31       22       13       5    0
///   +-------+^------+-^-----+-^-----
///   |b=9bits |c=9bits |a=8bits|op=6|
///   +-------+^------+-^-----+-^-----
///   |    bx=18bits    |a=8bits|op=6|
///   +-------+^------+-^-----+-^-----
///   |   sbx=18bits    |a=8bits|op=6|
///   +-------+^------+-^-----+-^-----
///   |    ax=26bits            |op=6|
///   +-------+^------+-^-----+-^-----
///  31      23      15       7      0
/// In IABC mode, the extra bits in b and c are used to differentiate between registers and constants.
/// If the extra bit is set, the value is an index into the constant table.
/// If the extra bit is not set, the value is an index into the register table.

type OpMode byte

const (
	iABC OpMode = iota
	iABx
	iAsBx
	iAx
	iNone
)

type BytecodeInstruction int32

func (inst BytecodeInstruction) Opcode() int {
	return int(inst & 0x3F)
}

func (inst BytecodeInstruction) A() int {
	return int((inst >> 6) & 0xFF)
}

func (inst BytecodeInstruction) B() int {
	return int((inst >> 23) & 0x1FF)
}

func (inst BytecodeInstruction) C() int {
	return int((inst >> 14) & 0x1FF)
}

func (inst BytecodeInstruction) Bx() int {
	return int((inst >> 14) & 0x3FFFF)
}

func (inst BytecodeInstruction) sBx() int {
	return inst.Bx() - 0x1FFFF
}

func (inst BytecodeInstruction) Ax() int {
	return int((inst >> 6) & 0x3FFFFFF)
}

type OpCodeName byte

const (
	opLoadConstant  OpCodeName = iota // 0  iABx
	opLoadBool                        // 1  iABC
	opLoadClosure                     // 2  iAx  
	opAdd                             // 3  iABC
	opSub                             // 4  iABC
	opMul                             // 5  iABC
	opDiv                             // 6  iABC
	opMod                             // 7  iABC
	opNeg                             // 8  iABC
	opNot                             // 9  iABC
	opEq                              // 10 iABC
	opLt                              // 11 iABC
	opLeq                             // 12 iABC
	opMove                            // 13 iAsBx 
	opPush                            // 14 iABx
	opPop                             // 15 iABx
	opReturn                          // 16 iABx
	opNewTable                        // 17 iABC
	opSetTable                        // 18 iABC
	opGetTable                        // 19 iABC
	opSetUpvalue                      // 20 iAx   
	opGetUpvalue                      // 21 iAx   
	opCloseUpvalues                   // 22 iAx   
	opTest                            // 23 iABC
	opJump                            // 24 iAsBx
	opCall                            // 25 iABC
	opType                            // 26 iABC
)
