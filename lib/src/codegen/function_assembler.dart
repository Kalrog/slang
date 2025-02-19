import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class LocalVar {
  /// Register index of the local variable
  final int register;

  /// Name of the local variable
  final String name;

  /// Scope of the local variable
  final int scope;

  /// Previous definition of a local variable with the same name
  /// that is shadowed by this one
  LocalVar? previous;

  bool _captured = false;

  LocalVar(this.previous, this.register, this.name, this.scope);

  /// Whether the local variable is captured
  bool get captured => _captured;

  void capture() {
    _captured = true;
  }
}

class Upvalue {
  /// Position of upvalue in the upvalue table
  final int index;

  /// Position of the referenced local variable in the parents stack
  final int localVarRegister;

  /// Position of the referenced upvalue in the parents upvalue table
  final int upvalueIndex;

  Upvalue(this.index, this.localVarRegister, this.upvalueIndex);
}

class FunctionAssembler {
  final FunctionAssembler? parent;
  final List<int> _instructions = [];
  final Map<Object?, int> _constants = {};
  final Map<String, LocalVar> _locals = {};
  final Map<String, Upvalue> _upvalues = {};
  final List<FunctionAssembler> children = [];
  int usedRegisters = 0;
  int maxRegisters = 0;
  int scope = 0;

  FunctionAssembler({this.parent});

  LocalVar? getLocalVar(String name) {
    if (_locals.containsKey(name)) {
      return _locals[name]!;
    }
    return null;
  }

  LocalVar createLocalVar(String name) {
    final register = allocateRegister();
    final localVar = LocalVar(_locals[name], register, name, scope);
    _locals[name] = localVar;
    return localVar;
  }

  Upvalue? getUpvalue(String name) {
    ///check if it's a known upvalue
    if (_upvalues.containsKey(name)) {
      return _upvalues[name]!;
    }

    /// if we have a parent, check if it has a local value with the same name
    if (parent != null) {
      final localVar = parent!.getLocalVar(name);
      if (localVar != null) {
        localVar.capture();
        final index = _upvalues.length;
        final upvalue = Upvalue(index, localVar.register, -1);
        _upvalues[name] = upvalue;
        return upvalue;
      }

      /// if the parent has an upvalue with the same name, return it
      final upvalue = parent!.getUpvalue(name);
      if (upvalue != null) {
        final index = _upvalues.length;
        final newUpvalue = Upvalue(index, -1, upvalue.index);
        _upvalues[name] = newUpvalue;
        return newUpvalue;
      }
    }

    return null;
  }

  void freeLocal(LocalVar localVar) {
    if (localVar.previous != null) {
      _locals[localVar.name] = localVar.previous!;
    } else {
      _locals.remove(localVar.name);
      freeRegister();
    }
  }

  void enterScope() {
    scope++;
  }

  void leaveScope() {
    final locals = _locals.values.where((l) => l.scope == scope).toList();
    closeOpenUpvalues(locals);
    for (final localVar in locals) {
      freeLocal(localVar);
    }
    if (scope > 1) {
      emitPop(0, locals.length);
    }
    scope--;
  }

  void closeOpenUpvalues(List<LocalVar> locals) {
    //Find the lowest slot containing a captured local variable
    int minSlot = maxRegisters;
    bool hasAnyCaptured = false;
    for (final local in locals) {
      for (LocalVar? current = local;
          current != null && current.scope == scope;
          current = current.previous) {
        if (current.captured) {
          hasAnyCaptured = true;
          if (current.register < minSlot) {
            minSlot = current.register;
          }
        }
      }
    }

    if (!hasAnyCaptured) {
      return;
    }

    //Close upvalues
    emitCloseUpvalues(minSlot);
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
      _upvalues.values.toList(),
      _upvalues.keys.toList(),
      children.map((c) => c.assemble()).toList(),
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

  void emitSetUpvalue(int index) {
    emitAx(OpCodeName.setUpvalue, index);
  }

  void emitGetUpvalue(int index) {
    emitAx(OpCodeName.getUpvalue, index);
  }

  void emitCloseUpvalues(int minSlot) {
    emitAx(OpCodeName.closeUpvalues, minSlot);
  }

  void emitLoadClosure(int index) {
    emitAx(OpCodeName.loadClosure, index);
  }

  void emitCall(int argCount) {
    emitABx(OpCodeName.call, 0, argCount);
  }
}
