import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/codegen/pattern_assembler.dart';
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

class UpvalueDef {
  /// Name of the upvalue
  final String name;

  /// Position of upvalue in the upvalue table
  final int index;

  /// Position of the referenced local variable in the parents stack
  final int localVarRegister;

  /// Position of the referenced upvalue in the parents upvalue table
  final int upvalueIndex;

  UpvalueDef(this.name, this.index, this.localVarRegister, this.upvalueIndex);

  Upvalue toUpvalue() {
    if (localVarRegister >= 0) {
      return Upvalue(name, localVarRegister, true);
    } else {
      return Upvalue(name, upvalueIndex, false);
    }
  }
}

class SourceLocation {
  final String origin;
  final int line;
  final int column;

  SourceLocation(this.origin, this.line, this.column);

  SourceLocation.fromJson(Map<String, dynamic> json)
      : line = json['line'],
        column = json['column'],
        origin = json['origin'];

  Map<String, dynamic> toJson() {
    return {
      'origin': origin,
      'line': line,
      'column': column,
    };
  }

  @override
  String toString() {
    return '$origin:$line:$column';
  }
}

class SourceLocationInfo {
  final int firstInstruction;
  final SourceLocation location;

  SourceLocationInfo(this.firstInstruction, this.location);

  SourceLocationInfo.fromJson(Map<String, dynamic> json)
      : firstInstruction = json['firstInstruction'],
        location = SourceLocation.fromJson(json['location']);

  Map<String, dynamic> toJson() {
    return {
      'firstInstruction': firstInstruction,
      'location': location.toJson(),
    };
  }
}

class Scope {
  final bool breakable;
  final List<int> breakJumps = [];
  Scope(this.breakable);
}

class FunctionAssembler {
  final FunctionAssembler? parent;
  final String origin;
  final List<int> _instructions = [];
  final List<SourceLocationInfo> _sourceLocations = [];
  final List<PatternAssembler> _patternAssemblers = [];
  final Map<Object?, int> _constants = {};
  final Map<String, LocalVar> _locals = {};
  final Map<String, UpvalueDef> _upvalues = {};
  final List<FunctionAssembler> children = [];
  final List<Scope> _scopes = [];

  final int nargs;
  final bool isVarArg;
  int usedRegisters = 0;
  int maxRegisters = 0;
  int scope = 0;

  FunctionAssembler({this.parent, String? origin, this.nargs = 0, this.isVarArg = false})
      : assert(origin != null || parent != null),
        origin = origin ?? parent!.origin;

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

  UpvalueDef? getUpvalue(String name) {
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

        final upvalue = UpvalueDef(name, index, localVar.register, -1);
        _upvalues[name] = upvalue;
        return upvalue;
      }

      /// if the parent has an upvalue with the same name, return it
      final upvalue = parent!.getUpvalue(name);
      if (upvalue != null) {
        final index = _upvalues.length;
        final newUpvalue = UpvalueDef(name, index, -1, upvalue.index);
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

  void enterScope({bool breakable = false}) {
    scope++;
    _scopes.add(Scope(breakable));
  }

  void leaveScope() {
    final locals = _locals.values.where((l) => l.scope == scope).toList();
    for (final localVar in locals) {
      freeLocal(localVar);
    }
    final leavingScope = _scopes.removeLast();
    for (final jump in leavingScope.breakJumps) {
      patchJump(jump);
    }
    // if (scope > 1) {
    //   emitPop(0, locals.length);
    // }
    scope--;
  }

  void closeOpenUpvalues() {
    //Find the lowest slot containing a captured local variable
    final locals = _locals.values.where((l) => l.scope == scope).toList();
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

  void setLocation(Token? token) {
    if (token == null) {
      return;
    }
    if (_sourceLocations.lastOrNull?.firstInstruction == _instructions.length) {
      return;
    }
    _sourceLocations.add(
        SourceLocationInfo(_instructions.length, SourceLocation(origin, token.line, token.column)));
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

  int emitJump([int? target]) {
    final int sbx;
    if (target != null) {
      sbx = target - _instructions.length - 1;
    } else {
      sbx = 0;
    }
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

  void emitBreak() {
    final breakAbleScope = _scopes.lastWhere((s) => s.breakable,
        orElse: () => throw Exception("Cannot break outside of a loop"));

    final jump = emitJump();
    breakAbleScope.breakJumps.add(jump);
  }

  void emitPop([int keep = 0, int pop = 1]) {
    emitABx(OpCodeName.pop, keep, pop);
  }

  int get nextInstructionIndex => _instructions.length;

  FunctionPrototype assemble() {
    return FunctionPrototype(
      _instructions,
      _sourceLocations,
      _constantsToList(),
      _upvaluesToList(),
      children.map((c) => c.assemble()).toList(),
      maxVarStackSize: maxRegisters,
      nargs: nargs,
      isVarArg: isVarArg,
    );
  }

  List<Object?> _constantsToList() {
    final constants = List<Object?>.filled(_constants.length, null);
    _constants.forEach((key, value) {
      constants[value] = key;
    });
    return constants;
  }

  List<Upvalue> _upvaluesToList() {
    final upvalues = List<Upvalue>.filled(_upvalues.length, Upvalue("", 0, false));
    _upvalues.forEach((key, value) {
      upvalues[value.index] = value.toUpvalue();
    });
    return upvalues;
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

  void emitType() {
    emit(OpCodeName.type);
  }

  PatternAssembler startPattern() {
    final patternAssembler = PatternAssembler(this);
    _patternAssemblers.add(patternAssembler);
    return patternAssembler;
  }

  PatternAssembler? get currentPattern => _patternAssemblers.lastOrNull;

  void endPattern() {
    if (_patternAssemblers.isEmpty) {
      throw StateError('No pattern to end');
    }
    _patternAssemblers.removeLast();
  }
}
