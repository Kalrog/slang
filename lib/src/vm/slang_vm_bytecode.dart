import 'package:slang/src/vm/slang_vm.dart';
import 'package:slang/src/vm/slang_vm_instructions.dart';

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
/// In IABC mode, the extra bits in  b and c are used to differentiate between registers and constants.
/// If the extra bit is set, the value is an index into the constant table.
/// If the extra bit is not set, the value is an index into the register table.
enum OpMode {
  iABC,
  iABx,
  iAsBx,
  iAx,
}

extension BytecodeInstruction on int {
  int get opcode => this & 0x3F;

  OpCode get op => opCodes[opcode];

  int get a => (this >> 6) & 0xFF;

  int get c => (this >> 14) & 0x1FF;

  int get b => (this >> 23) & 0x1FF;

  int get bx => this >> 14;

  int get sbx => bx - 0x1FFFF;

  int get ax => this >> 6;
}

typedef Instruction = void Function(SlangVm vm, int instruction);

enum OpCodeName {
  loadConstant,
  add,
  sub,
  mul,
  div,
  mod,
  neg,
  move,
  returnOp,
  newTable,
  setTable,
  getTable,
}

class OpCode {
  final OpCodeName name;
  final OpMode mode;
  final Instruction execute;

  const OpCode(this.name, this.mode, this.execute);
}

const opCodes = <OpCode>[
  OpCode(OpCodeName.loadConstant, OpMode.iABx, Instructions.loadConstant), // R(A) := Kst(Bx)
  OpCode(OpCodeName.add, OpMode.iABC, Instructions.add), // R(A) := RK(B) + RK(C)
  OpCode(OpCodeName.sub, OpMode.iABC, Instructions.sub), // R(A) := RK(B) - RK(C)
  OpCode(OpCodeName.mul, OpMode.iABC, Instructions.mul), // R(A) := RK(B) * RK(C)
  OpCode(OpCodeName.div, OpMode.iABC, Instructions.div), // R(A) := RK(B) / RK(C)
  OpCode(OpCodeName.mod, OpMode.iABC, Instructions.mod), // R(A) := RK(B) % RK(C)
  OpCode(OpCodeName.neg, OpMode.iABC, Instructions.neg), // R(A) := -R(B)
  OpCode(OpCodeName.move, OpMode.iABC, Instructions.move), // R(A) := R(B)
  OpCode(OpCodeName.returnOp, OpMode.iAx, Instructions.returnOp), // return R(A)
  OpCode(
      OpCodeName.newTable,
      OpMode.iABC,
      Instructions
          .newTable), // R(A) := {} (b: number of array elements, c: number of hash elements)
  OpCode(OpCodeName.setTable, OpMode.iABC, Instructions.setTable), // R(A)[RK(B)] := RK(C)
  OpCode(OpCodeName.getTable, OpMode.iABC, Instructions.getTable), // R(A) := R(B)[RK(C)]
];

void printInstruction(int instruction) {
  final opcode = instruction.opcode;
  final op = opCodes[opcode];
  switch (op.mode) {
    case OpMode.iABC:
      print('${op.name.name} A=${instruction.a} B=${instruction.b} C=${instruction.c}');
      break;
    case OpMode.iABx:
      print('${op.name.name} A=${instruction.a} Bx=${instruction.bx}');
      break;
    case OpMode.iAsBx:
      print('${op.name.name} A=${instruction.a} sBx=${instruction.sbx}');
      break;
    case OpMode.iAx:
      print('${op.name.name} Ax=${instruction.ax}');
      break;
  }
}

void printInstructions(List<int> instructions) {
  for (var i = 0; i < instructions.length; i++) {
    printInstruction(instructions[i]);
  }
}
