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
  iNone,
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
  loadBool,
  loadClosure,
  add,
  sub,
  mul,
  div,
  mod,
  neg,
  not,
  eq,
  lt,
  leq,
  move,
  push,
  pop,
  returnOp,
  newTable,
  setTable,
  getTable,
  setUpvalue,
  getUpvalue,
  closeUpvalues,
  test,
  jump,
  call,
  type,
}

class OpCode {
  final OpCodeName name;
  final OpMode mode;
  final Instruction execute;

  const OpCode(this.name, this.mode, this.execute);
}

const opCodes = <OpCode>[
  OpCode(OpCodeName.loadConstant, OpMode.iABx,
      Instructions.loadConstant), // Put constant K[Bx] onto the stack
  OpCode(
      OpCodeName.loadBool,
      OpMode.iABC,
      Instructions
          .loadBool), //Put constant (bool) A onto the stack and if(B) pc++
  OpCode(OpCodeName.loadClosure, OpMode.iAx,
      Instructions.loadClosure), // put closure Closure[Ax] onto the stack
  // Arithmetic operations
  // always take top elements of the stack and apply, then push result
  OpCode(OpCodeName.add, OpMode.iNone, Instructions.add),
  OpCode(OpCodeName.sub, OpMode.iNone, Instructions.sub),
  OpCode(OpCodeName.mul, OpMode.iNone, Instructions.mul),
  OpCode(OpCodeName.div, OpMode.iNone, Instructions.div),

  OpCode(OpCodeName.mod, OpMode.iNone, Instructions.mod),
  OpCode(OpCodeName.neg, OpMode.iNone, Instructions.neg),
  OpCode(OpCodeName.not, OpMode.iNone, Instructions.not),
  OpCode(OpCodeName.eq, OpMode.iNone, Instructions.eq),
  OpCode(OpCodeName.lt, OpMode.iNone, Instructions.lt),
  OpCode(OpCodeName.leq, OpMode.iNone, Instructions.leq),
  OpCode(OpCodeName.move, OpMode.iAsBx,
      Instructions.move), //Pop top of stack and put it in Stack[sBx]
  OpCode(OpCodeName.push, OpMode.iAsBx,
      Instructions.push), // push Stack[sBx] to top
  OpCode(
      OpCodeName.pop,
      OpMode.iABx,
      Instructions
          .pop), // keep the top A elements of the stack and pop Bx elements underneath
  OpCode(OpCodeName.returnOp, OpMode.iNone,
      Instructions.returnOp), //  return top of stack
  OpCode(
      OpCodeName.newTable,
      OpMode.iABC,
      Instructions
          .newTable), // push {} (b: number of array elements, c: number of hash elements)
  OpCode(
      OpCodeName.setTable,
      OpMode.iNone,
      Instructions
          .setTable), // Stack(-3)[Stack(-2)] = Stack(-1) (will pop the top 3 elements)

  OpCode(OpCodeName.getTable, OpMode.iNone,
      Instructions.getTable), // push Stack(-2)[Stack(-1)] (will pop
  OpCode(OpCodeName.setUpvalue, OpMode.iAx,
      Instructions.setUpvalue), // upvalue[Ax] = Stack(-1)(will pop stack)
  OpCode(OpCodeName.getUpvalue, OpMode.iAx,
      Instructions.getUpvalue), // push upvalue[Ax]
  OpCode(OpCodeName.closeUpvalues, OpMode.iAx,
      Instructions.closeUpvalues), // close all upvalues with index >= Ax
  OpCode(
      OpCodeName.test,
      OpMode.iABC,
      Instructions
          .test), // if not (Stack(-1) <=> C) then pc++ (pops top of stack)
  OpCode(OpCodeName.jump, OpMode.iAsBx, Instructions.jump), // pc+=sBx
  OpCode(OpCodeName.call, OpMode.iABx, Instructions.call), // call function
  OpCode(OpCodeName.type, OpMode.iNone,
      Instructions.type), // replace Stack(-1) with string of it's type
];

String instructionToString(int instruction) {
  final opcode = instruction.opcode;
  final op = opCodes[opcode];
  return switch (op.mode) {
    OpMode.iABC =>
      '${op.name.name} A=${instruction.a} B=${instruction.b} C=${instruction.c}',
    OpMode.iABx => '${op.name.name} A=${instruction.a} Bx=${instruction.bx}',
    OpMode.iAsBx => '${op.name.name} A=${instruction.a} sBx=${instruction.sbx}',
    OpMode.iAx => '${op.name.name} Ax=${instruction.ax}',
    OpMode.iNone => op.name.name,
  };
}
