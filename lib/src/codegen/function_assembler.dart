import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class LocalVar {
  final int register;
  final String name;

  LocalVar(this.register, this.name);
}

class FunctionAssembler {
  final List<int> _instructions = [];
  final Map<Object?, int> _constants = {};
  final Map<String, LocalVar> _locals = {};
  int usedRegisters = 0;
  int maxRegisters = 0;

  LocalVar getLocalVar(String name) {
    if (_locals.containsKey(name)) {
      return _locals[name]!;
    }
    final register = allocateRegister();
    final localVar = LocalVar(register, name);
    _locals[name] = localVar;
    return localVar;
  }

  void freeLocal(LocalVar localVar) {
    _locals.remove(localVar.name);
  }

  int allocateRegister() {
    final register = usedRegisters++;
    if (usedRegisters > 255) {
      throw StateError('Too many registers');
    }
    if (usedRegisters > maxRegisters) {
      maxRegisters = usedRegisters;
    }
    return register;
  }

  int allocateRegisters(int count) {
    final start = usedRegisters;
    for (var i = 0; i < count; i++) {
      allocateRegister();
    }
    return start;
  }

  int freeRegister() {
    if (usedRegisters == 0) {
      throw StateError('No registers to free');
    }
    return --usedRegisters;
  }

  void freeRegisters(int count) {
    for (var i = 0; i < count; i++) {
      freeRegister();
    }
  }

  int indexOfConstant(Object? value) {
    if (_constants.containsKey(value)) {
      return _constants[value]!;
    }
    final index = _constants.length;
    _constants[value] = index;
    return index;
  }

  void emitABC(OpCodeName opcode, int a, int b, int c) {
    int instruction = b << 23 | c << 14 | a << 6 | opcode.index;
    _instructions.add(instruction);
  }

  void emitABx(OpCodeName opcode, int a, int bx) {
    int instruction = bx << 14 | a << 6 | opcode.index;
    _instructions.add(instruction);
  }

  void emitAsBx(OpCodeName opcode, int a, int sbx) {
    int instruction = (sbx + 0x1FFFF) << 14 | a << 6 | opcode.index;
    _instructions.add(instruction);
  }

  void emitAx(OpCodeName opcode, int ax) {
    int instruction = ax << 6 | opcode.index;
    _instructions.add(instruction);
  }

  void emitLoadConstant(int a, Object? value) {
    final index = indexOfConstant(value);
    emitABx(OpCodeName.loadConstant, a, index);
  }

  void emitAdd(int a, int b, int c) {
    emitABC(OpCodeName.add, a, b, c);
  }

  void emitSub(int a, int b, int c) {
    emitABC(OpCodeName.sub, a, b, c);
  }

  void emitMul(int a, int b, int c) {
    emitABC(OpCodeName.mul, a, b, c);
  }

  void emitDiv(int a, int b, int c) {
    emitABC(OpCodeName.div, a, b, c);
  }

  void emitMod(int a, int b, int c) {
    emitABC(OpCodeName.mod, a, b, c);
  }

  void emitNeg(int a, int b) {
    emitABC(OpCodeName.neg, a, b, 0);
  }

  void emitBinOp(int a, int b, int c, String op) {
    switch (op) {
      case '+':
        emitAdd(a, b, c);
        break;
      case '-':
        emitSub(a, b, c);
        break;
      case '*':
        emitMul(a, b, c);
        break;
      case '/':
        emitDiv(a, b, c);
        break;
      case '%':
        emitMod(a, b, c);
        break;
      default:
        throw ArgumentError('Unknown operator: $op');
    }
  }

  void emitUnOp(int a, int b, String op) {
    switch (op) {
      case '-':
        emitNeg(a, b);
        break;
      default:
        throw ArgumentError('Unknown operator: $op');
    }
  }

  void emitReturn(int a) {
    emitAx(OpCodeName.returnOp, a);
  }

  void emitMove(int to, int from) {
    emitABC(OpCodeName.move, to, from, 0);
  }

  void emitNewTable(int a, int b, int c) {
    emitABC(OpCodeName.newTable, a, b, c);
  }

  void emitSetTable(int a, int b, int c) {
    emitABC(OpCodeName.setTable, a, b, c);
  }

  void emitGetTable(int a, int b, int c) {
    emitABC(OpCodeName.getTable, a, b, c);
  }

  FunctionPrototype assemble() {
    return FunctionPrototype(
      _instructions,
      _constantsToList(),
      maxStackSize: maxRegisters,
    );
  }

  List<Object?> _constantsToList() {
    final constants = List<Object?>.filled(_constants.length, null);
    _constants.forEach((key, value) {
      constants[value] = key;
    });
    return constants;
  }
}
