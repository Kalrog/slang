import 'package:slang/src/slang_vm.dart';
import 'package:slang/src/vm/slang_vm.dart';

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
  /// The opcode uses the A, B, and C fields to extract arguments.
  iABC,

  /// The opcode uses the A and Bx fields to extract arguments.
  iABx,

  /// The opcode uses the A and sBx fields to extract arguments.
  iAsBx,

  /// The opcode uses the Ax field to extract arguments.
  iAx,

  /// The opcode does not use any arguments.
  iNone,
}

/// Utility extension on [int] to extract the different fields from a bytecode instruction.
extension BytecodeInstruction on int {
  /// Extracts the opcode number from the instruction.
  int get opcode => this & 0x3F;

  /// Extracts the opcode from the instruction.
  OpCode get op => opCodes[opcode];

  /// Extracts the A field from the instruction.
  int get a => (this >> 6) & 0xFF;

  /// Extracts the B field from the instruction.
  int get c => (this >> 14) & 0x1FF;

  /// Extracts the C field from the instruction.
  int get b => (this >> 23) & 0x1FF;

  /// Extracts the extended B (Bx) field from the instruction.
  int get bx => this >> 14;

  /// Extracts the signed extended B (sBx) field from the instruction.
  int get sbx => bx - 0x1FFFF;

  /// Extracts the extended A (Ax) field from the instruction.
  int get ax => this >> 6;
}

/// Instructions for the Slang VM.
/// [instruction] is the bytecode instruction that the VM will execute and contains the opcode and arguments.
/// [vm] is the VM that is executing the instruction.
/// The function itself is responsible for extracting the arguments from the bytecode instruction
/// and calling the appropriate function on the VM to execute the instruction.
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

/// [OpCode] implement the different operations that the Slang VM can execute.
/// Each [OpCode] defines an [Instruction] that is executed when the opcode is encountered.
/// The [OpCode] also defines the [OpMode] that the opcode uses to extract the arguments from the bytecode.
/// While not necessary for the VM to function, they also have an associated [OpCodeName] for debugging purposes
/// and to make the code generator easier to read.
class OpCode {
  /// The name of the opcode.
  final OpCodeName name;

  /// The mode that the opcode uses to extract arguments from the bytecode.
  final OpMode mode;

  /// The instruction that the opcode executes.
  final Instruction execute;

  /// Creates a new opcode with the given [name], [mode], and [execute] function.
  const OpCode(this.name, this.mode, this.execute);
}

const opCodes = <OpCode>[
  OpCode(OpCodeName.loadConstant, OpMode.iABx,
      Instructions.loadConstant), // Put constant K[Bx] onto the stack
  OpCode(OpCodeName.loadBool, OpMode.iABC,
      Instructions.loadBool), //Put constant (bool) A onto the stack and if(B) pc++
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
  OpCode(
      OpCodeName.move, OpMode.iAsBx, Instructions.move), //Pop top of stack and put it in Stack[sBx]
  OpCode(OpCodeName.push, OpMode.iAsBx, Instructions.push), // push Stack[sBx] to top
  OpCode(OpCodeName.pop, OpMode.iABx,
      Instructions.pop), // keep the top A elements of the stack and pop Bx elements underneath
  OpCode(OpCodeName.returnOp, OpMode.iNone, Instructions.returnOp), //  return top of stack
  OpCode(OpCodeName.newTable, OpMode.iABC,
      Instructions.newTable), // push {} (b: number of array elements, c: number of hash elements)
  OpCode(OpCodeName.setTable, OpMode.iNone,
      Instructions.setTable), // Stack(-3)[Stack(-2)] = Stack(-1) (will pop the top 3 elements)

  OpCode(OpCodeName.getTable, OpMode.iNone,
      Instructions.getTable), // push Stack(-2)[Stack(-1)] (will pop
  OpCode(OpCodeName.setUpvalue, OpMode.iAx,
      Instructions.setUpvalue), // upvalue[Ax] = Stack(-1)(will pop stack)
  OpCode(OpCodeName.getUpvalue, OpMode.iAx, Instructions.getUpvalue), // push upvalue[Ax]
  OpCode(OpCodeName.closeUpvalues, OpMode.iAx,
      Instructions.closeUpvalues), // close all upvalues with index >= Ax
  OpCode(OpCodeName.test, OpMode.iABC,
      Instructions.test), // if not (Stack(-1) <=> C) then pc++ (pops top of stack)
  OpCode(OpCodeName.jump, OpMode.iAsBx, Instructions.jump), // pc+=sBx
  OpCode(OpCodeName.call, OpMode.iABx, Instructions.call), // call function
  OpCode(OpCodeName.type, OpMode.iNone,
      Instructions.type), // replace Stack(-1) with string of it's type
];

String instructionToString(int instruction) {
  final opcode = instruction.opcode;
  final op = opCodes[opcode];
  return switch (op.mode) {
    OpMode.iABC => '${op.name.name} A=${instruction.a} B=${instruction.b} C=${instruction.c}',
    OpMode.iABx => '${op.name.name} A=${instruction.a} Bx=${instruction.bx}',
    OpMode.iAsBx => '${op.name.name} A=${instruction.a} sBx=${instruction.sbx}',
    OpMode.iAx => '${op.name.name} Ax=${instruction.ax}',
    OpMode.iNone => op.name.name,
  };
}
