import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class LocalVar {
  final int register;
  final String name;
  final int scope;

  LocalVar(this.register, this.name, this.scope);
}

class FunctionAssembler {
  final List<int> _instructions = [];
  final Map<Object?, int> _constants = {};
  final Map<String, LocalVar> _locals = {};
  int usedRegisters = 0;
  int maxRegisters = 0;
  int scope = 0;

  LocalVar getLocalVar(String name) {
    if (_locals.containsKey(name)) {
      return _locals[name]!;
    }
    final register = allocateRegister();
    final localVar = LocalVar(register, name, scope);
    _locals[name] = localVar;
    return localVar;
  }

  void freeLocal(LocalVar localVar) {
    _locals.remove(localVar.name);
    freeRegister();
  }

  void enterScope() {
    scope++;
  }

  void leaveScope() {
    final locals = _locals.values.where((l) => l.scope == scope).toList();
    for (final localVar in locals) {
      freeLocal(localVar);
    }
    if (scope > 1) {
      emitPop(0, locals.length);
    }
    scope--;
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

  void emitABC(OpCodeName opcode, [int a = 0, int b = 0, int c = 0]) {
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

  void emit(OpCodeName opcode) {
    int instruction = opcode.index;
    _instructions.add(instruction);
  }

  void emitLoadConstant(Object? value) {
    final index = indexOfConstant(value);
    emitABx(OpCodeName.loadConstant, 0, index);
  }

  void emitBinOp(String op) {
    switch (op) {
      case '+':
        emit(OpCodeName.add);
      case '-':
        emit(OpCodeName.sub);
      case '*':
        emit(OpCodeName.mul);
      case '/':
        emit(OpCodeName.div);
      case '%':
        emit(OpCodeName.mod);
      case '<':
        emit(OpCodeName.lt);
      case '<=':
        emit(OpCodeName.leq);
      case "==":
        emit(OpCodeName.eq);
      default:
        throw ArgumentError('Unknown operator: "$op"');
    }
  }

  void emitUnOp(String op) {
    switch (op) {
      case '-':
        emit(
          OpCodeName.neg,
        );

      case 'not':
        emit(
          OpCodeName.not,
        );
      default:
        throw ArgumentError('Unknown operator: $op');
    }
  }

  void emitReturn() {
    emit(OpCodeName.returnOp);
  }

  void emitMove(int from) {
    emitAsBx(OpCodeName.move, 0, from);
  }

  void emitPush(int a) {
    emitAsBx(OpCodeName.push, 0, a);
  }

  void emitNewTable(int listElements, int hashElements) {
    emitABC(OpCodeName.newTable, 0, listElements, hashElements);
  }

  void emitSetTable() {
    emit(OpCodeName.setTable);
  }

  void emitGetTable() {
    emit(OpCodeName.getTable);
  }

  void emitLoadBool(bool b, {bool jump = false}) {
    emitABC(OpCodeName.loadBool, 0, b ? 1 : 0, jump ? 1 : 0);
  }

  void emitTest(bool c) {
    emitABC(OpCodeName.test, 0, 0, c ? 1 : 0);
  }

  int emitJump([int sbx = 0]) {
    emitAsBx(OpCodeName.jump, 0, sbx);
    return _instructions.length - 1;
  }

  void patchJump(int jump, [int? target]) {
    target = target ?? _instructions.length;
    final instruction = _instructions[jump];
    final opcode = instruction & 0x3F;
    final newSbx = target - jump - 1;
    final newInstruction = (newSbx + 0x1FFFF) << 14 | opcode;
    _instructions[jump] = newInstruction;
  }

  void emitPop([int keep = 0, int pop = 1]) {
    emitABx(OpCodeName.pop, keep, pop);
  }

  int get nextInstructionIndex => _instructions.length;

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
