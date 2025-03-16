import 'dart:io';

import 'package:slang/src/codegen/function_assembler.dart';
import 'package:slang/src/compiler.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class SlangStackFrame {
  int _pc = 0;
  late List stack = [];
  SlangStackFrame? parent;
  Closure? closure;
  Map<int, UpvalueHolder> openUpvalues = {};
  SlangStackFrame([this.closure, this.parent]);

  FunctionPrototype? get function => closure?.prototype;
  int get pc => _pc;

  int? get currentInstruction => function?.instructions[_pc];

  SourceLocation? get currentInstructionLocation {
    if (function == null) {
      return null;
    }
    var index = 0;
    for (final location in function!.sourceLocations) {
      if (location.firstInstruction > pc) {
        break;
      }
      index++;
    }
    if (index >= function!.sourceLocations.length) {
      return function!.sourceLocations.last.location;
    }
    return function!.sourceLocations[index].location;
  }

  void addPc(int n) {
    _pc += n;
  }

  int absIndex(int index) {
    if (index < 0) {
      return stack.length + index;
    }
    return index;
  }

  void push(dynamic value) {
    stack.add(value);
    if (stack.length > 5000) {
      throw Exception("Stack overflow");
    }
  }

  dynamic pop([int n = 1]) {
    // return stack.removeLast();
    if (n == 0) {
      return null;
    }
    if (n == 1) {
      return stack.removeLast();
    }
    final result = stack.sublist(stack.length - n);
    stack.removeRange(stack.length - n, stack.length);
    return result;
  }

  operator [](int index) {
    final absIdx = absIndex(index);
    if (absIdx >= stack.length || absIdx < 0) {
      return null;
    }
    return stack[absIdx];
  }

  operator []=(int index, dynamic value) {
    final absIdx = absIndex(index);
    stack[absIdx] = value;
  }

  @override
  String toString() {
    StringBuffer buffer = StringBuffer();
    for (var i = stack.length - 1; i >= 0; i--) {
      // 2  | int | 42
      // 1  | int | 12
      // 0  | int | 30
      buffer.writeln(
          '${i.toString().padLeft(3)}  | ${stack[i].runtimeType.toString().padRight(8)} | ${stack[i]}');
    }
    return buffer.toString();
  }

  int get top => stack.length;

  void setTop(int top) {
    if (top < stack.length) {
      stack.removeRange(top, stack.length);
    } else {
      stack.addAll(List.filled(top - stack.length, null));
    }
  }
}

enum BinOpType { add, sub, mul, div, mod }

enum RelOpType {
  lt,
  leq,
  eq,
}

enum UnOpType { neg, not }

enum ExecutionMode { run, step, runDebug }

class SlangVm {
  SlangStackFrame _frame = SlangStackFrame();
  final SlangTable globals = SlangTable();
  ExecutionMode mode = ExecutionMode.run;

  void execUnOp(UnOpType op) {
    final a = _frame.pop();
    switch (op) {
      case UnOpType.neg:
        _frame.push(-a);
      case UnOpType.not:
        _frame.push(!a);
    }
  }

  void execBinOp(BinOpType op) {
    final b = _frame.pop();
    final a = _frame.pop();
    switch (op) {
      case BinOpType.add:
        _frame.push(a + b);
      case BinOpType.sub:
        _frame.push(a - b);
      case BinOpType.mul:
        _frame.push(a * b);
      case BinOpType.div:
        _frame.push(a / b);
      case BinOpType.mod:
        _frame.push(a % b);
    }
  }

  void execRelOp(RelOpType op) {
    final b = _frame.pop();
    final a = _frame.pop();
    switch (op) {
      case RelOpType.lt:
        _frame.push(a < b);
      case RelOpType.leq:
        _frame.push(a <= b);
      case RelOpType.eq:
        _frame.push(a == b);
    }
  }

  void push(dynamic value) {
    _frame.push(value);
  }

  void pushValue(int index) {
    _frame.push(_frame[index]);
  }

  void pop([int keep = 0, int pop = 1]) {
    final popped = _frame.pop(pop + keep);
    if (keep > 0) {
      final kept = popped.sublist(pop);
      _frame.stack.addAll(kept);
    }
  }

  int getTop() {
    return _frame.top;
  }

  void replace(int index) {
    _frame[index] = _frame.pop();
  }

  void loadConstant(int index) {
    final k = _frame.function!.constants[index];
    _frame.push(k);
  }

  void newTable([int nArray = 0, int nHash = 0]) {
    _frame.push(SlangTable(nArray, nHash));
  }

  void setTable() {
    final value = _frame.pop();
    final key = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    _setTable(table, key, value);
  }

  void appendTable() {
    final value = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    table[table.length] = value;
  }

  void _setTable(SlangTable table, Object key, Object? value) {
    // table[key] = value;
    if (table[key] != null ||
        table.metatable == null ||
        table.metatable!["__newindex"] == null) {
      table[key] = value;
      return;
    }

    final metatable = table.metatable!;
    final newindex = metatable["__newindex"];
    switch (newindex) {
      case Closure closure:
        _frame.push(closure);
        _frame.push(table);
        _frame.push(key);
        _frame.push(value);
        call(3);
        return;
      case SlangTable table:
        _setTable(table, key, value);
        return;
      default:
        return;
    }
  }

  void getTable() {
    final key = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    _getTable(table, key);
  }

  void _getTable(SlangTable table, Object key) {
    final value = table[key];
    if (value != null ||
        table.metatable == null ||
        table.metatable!["__index"] == null) {
      _frame.push(value);
      return;
    }
    final metatable = table.metatable!;
    final index = metatable["__index"];
    switch (index) {
      case Closure closure:
        _frame.push(closure);
        _frame.push(table);
        _frame.push(key);
        call(2);
        return;
      case SlangTable table:
        _getTable(table, key);
        return;
      default:
        _frame.push(null);
        return;
    }
  }

  void setUpvalue(int index) {
    final value = _frame.pop();
    final upvalue = _frame.closure!.upvalues[index];
    upvalue!.set(value);
  }

  void getUpvalue(int index) {
    final upvalue = _frame.closure!.upvalues[index];
    _frame.push(upvalue!.get());
  }

  void closeUpvalues(int fromIndex) {
    _frame.openUpvalues.removeWhere((_, upvalue) {
      if (upvalue.index >= fromIndex) {
        upvalue.migrate();
        return true;
      }
      return false;
    });
  }

  void compile(String code, {bool repl = false, String origin = "string"}) {
    final prototype = repl ? compileREPL(code) : compileSource(code, origin);
    Closure closure = Closure.slang(prototype);
    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    _frame.push(closure);
  }

  void loadClosure(int index) {
    final prototype = _frame.function!.children[index];
    Closure closure = Closure.slang(prototype);
    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    for (final (index, uv) in prototype.upvalues.indexed) {
      if (uv.isLocal && _frame.openUpvalues[uv.index] != null) {
        closure.upvalues[index] = _frame.openUpvalues[uv.index];
      } else if (uv.isLocal) {
        closure.upvalues[index] = UpvalueHolder.stack(_frame, uv.index);
        _frame.openUpvalues[uv.index] = closure.upvalues[index]!;
      } else {
        closure.upvalues[index] = _frame.closure!.upvalues[uv.index];
      }
    }
    _frame.push(closure);
  }

  void call(int nargs) {
    bool isRoot = _frame.parent == null;
    var args = _frame.pop(nargs) ?? [];
    if (args is! List) {
      args = [args];
    }
    final closure = _frame.pop();
    if (closure is! Closure) {
      throw Exception('Expected Closure got $closure');
    }
    _pushStack(closure);
    if (closure.prototype != null) {
      final proto = closure.prototype!;
      final nargs = proto.isVarArg ? proto.nargs - 1 : proto.nargs;
      final extraArgs = SlangTable();
      for (final (index, arg) in args.indexed) {
        if (index < nargs) {
          _frame.push(arg);
        } else {
          extraArgs.add(arg);
        }
      }
      if (proto.isVarArg) {
        _frame.push(extraArgs);
      }
    } else {
      for (final arg in args) {
        _frame.push(arg);
      }
    }

    try {
      if (closure.prototype != null) {
        _frame.setTop(closure.prototype!.maxStackSize);
        _runSlangFunction();
      } else {
        _runDartFunction();
      }
    } catch (e, stack) {
      if (isRoot) {
        print(buildStackTrace());
        print("Error: $e");
        print("Stack: $stack");
      }
      rethrow;
    }
  }

  void pCall(int nargs) {
    final currentStack = _frame;
    try {
      call(nargs);
      newTable();
      pushValue(-1);
      push("ok");
      appendTable();
      pushValue(-1);
      pushValue(-3);
      appendTable();
      pop(1, 1);
    } catch (e, stack) {
      var err = e;
      if (err is! SlangException) {
        err = SlangException("$err ${buildStackTrace()} $stack",
            _frame.currentInstructionLocation);
      }
      while (_frame != currentStack) {
        _popStack();
      }
      newTable();
      pushValue(-1);
      push("err");
      appendTable();
      pushValue(-1);
      err.toSlang(this);
      appendTable();
      if (mode == ExecutionMode.runDebug) {
        mode = ExecutionMode.step;
        print(err);
      }
    }
  }

  void error(String message) {
    throw SlangException(message, _frame.parent?.currentInstructionLocation);
  }

  String buildStackTrace() {
    final buffer = StringBuffer();
    for (SlangStackFrame? frame = this._frame;
        frame != null;
        frame = frame.parent) {
      final location = frame.currentInstructionLocation;
      if (location != null) {
        buffer.writeln("unknown closure:$location");
      } else {
        buffer.writeln("unknown closure:unknown location");
      }
    }
    return buffer.toString();
  }

  void registerDartFunction(String name, DartFunction function) {
    globals[name] = Closure.dart(function);
  }

  void pushDartFunction(DartFunction function) {
    push(Closure.dart(function));
  }

  void _pushStack([Closure? closure]) {
    _frame = SlangStackFrame(closure, _frame);
  }

  void _popStack() {
    for (final upvalue in _frame.openUpvalues.values) {
      upvalue.migrate();
    }
    _frame = _frame.parent!;
  }

  void addPc(int n) {
    _frame.addPc(n);
  }

  void jump(int n) {
    addPc(n);
  }

  Set<int> breakPoints = {};
  void _runSlangFunction() {
    while (true) {
      final instruction = _frame.currentInstruction;
      final op = instruction!.op;

      bool brk = false;
      if (breakPoints.contains(_frame.pc) && mode == ExecutionMode.runDebug) {
        brk = true;
      }
      if (mode == ExecutionMode.step) {
        brk = true;
      }
      if (mode case ExecutionMode.runDebug || ExecutionMode.step) {
        debugPrint();
      }
      while (brk) {
        final instr = stdin.readLineSync();
        switch (instr) {
          case 'c':
            mode = ExecutionMode.runDebug;
            brk = false;
          case '.' || '':
            mode = ExecutionMode.step;
            brk = false;
          case 's' || 'stk' || 'stack':
            printStack();
          case 'i' || 'ins' || 'instructions':
            printInstructions();
          case 'c' || 'const' || 'constants':
            printConstants();
          case 'u' || 'up' || 'upvalues':
            printUpvalues();
          case 'd' || 'debug':
            debugPrintToggle = !debugPrintToggle;
          case _ when instr!.startsWith("toggle"):
            switch (instr.replaceFirst("toggle", "").trim()) {
              case 'i' || 'ins' || 'instructions':
                debugPrintInstructions = !debugPrintInstructions;
              case 's' || 'stk' || 'stack':
                debugPrintStack = !debugPrintStack;
              case 'c' || 'const' || 'constants':
                debugPrintConstants = !debugPrintConstants;
              case 'u' || 'up' || 'upvalues':
                debugPrintUpvalues = !debugPrintUpvalues;
              case 'o' || 'open' || 'openupvalues':
                debugPrintOpenUpvalues = !debugPrintOpenUpvalues;
            }
          default:
            // set [name] [value]
            final setRegex = RegExp(r'set (\w+) (.+)');
            final setMatch = setRegex.firstMatch(instr);
            if (setMatch != null) {
              final name = setMatch.group(1);
              final value = setMatch.group(2);
              switch (name) {
                case 'mode':
                  switch (value) {
                    case 'run':
                      mode = ExecutionMode.run;
                    case 'step':
                      mode = ExecutionMode.step;
                  }
                case 'instr_context':
                  debugInstructionContext = int.tryParse(value ?? "null");
              }
            }

            // b[reak] [pc]
            final breakRegex = RegExp(r'b(reak)? (\d+)?');
            final breakMatch = breakRegex.firstMatch(instr);
            if (breakMatch != null) {
              final pc = int.tryParse(breakMatch.group(2) ?? "null");
              if (pc != null) {
                if (breakPoints.contains(pc)) {
                  breakPoints.remove(pc);
                  print("Removed breakpoint at $pc");
                } else {
                  breakPoints.add(pc);
                  print("Set breakpoint at $pc");
                }
              }
            }
            //b(reak)? @line
            final breakLineRegex = RegExp(r'b(reak)? @(\d+)?');
            final breakLineMatch = breakLineRegex.firstMatch(instr);
            if (breakLineMatch != null) {
              final line = int.tryParse(breakLineMatch.group(2) ?? "null");

              if (line != null) {
                int? pc;
                for (int i = 1;
                    i < _frame.function!.sourceLocations.length;
                    i++) {
                  if (_frame.function!.sourceLocations[i].location.line ==
                      line) {
                    pc = _frame.function!.sourceLocations[i].firstInstruction;
                    break;
                  }
                  if (_frame.function!.sourceLocations[i].location.line >
                          line &&
                      _frame.function!.sourceLocations[i - 1].location.line <=
                          line) {
                    pc = _frame
                        .function!.sourceLocations[i - 1].firstInstruction;
                    break;
                  }
                }
                pc ??= _frame.function!.sourceLocations.last.firstInstruction;
                if (breakPoints.contains(pc)) {
                  breakPoints.remove(pc);
                  print("Removed breakpoint at $pc");
                } else {
                  breakPoints.add(pc);
                  print("Set breakpoint at $pc");
                }
              }
            }
        }
      }

      op.execute(this, instruction);
      if (op.name == OpCodeName.returnOp) {
        break;
      } else {
        addPc(1);
      }
    }
  }

  void _runDartFunction() {
    final function = _frame.closure!.dartFunction!;
    final returnsValue = function(this);
    Object? returnValue;
    if (returnsValue) {
      returnValue = _frame.pop();
    }
    _popStack();
    _frame.push(returnValue);
  }

  void returnOp(int n) {
    final result = _frame[n];
    _popStack();
    _frame.push(result);
  }

  Object? toAny(int n) {
    final value = _frame[n];
    return value;
  }

  int toInt(int n) {
    return _frame[n] as int;
  }

  String toString2(int n) {
    return _frame[n].toString();
  }

  bool toBool(int n) {
    return _frame[n] != null && _frame[n] != false;
  }

  double toDouble(int n) {
    return _frame[n] as double;
  }

  bool checkInt(int n) {
    return _frame[n] is int;
  }

  bool checkString(int n) {
    return _frame[n] is String;
  }

  bool checkTable(int n) {
    return _frame[n] is SlangTable;
  }

  bool checkDouble(int n) {
    return _frame[n] is double;
  }

  bool checkFunction(int n) {
    return _frame[n] is Closure;
  }

  bool checkNull(int n) {
    return _frame[n] == null;
  }

  int getIntArg(int n, {String? name, int? defaultValue}) {
    if (!checkInt(n)) {
      throw Exception(
          'Expected int for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toInt(n);
  }

  String getStringArg(int n, {String? name, String? defaultValue}) {
    if (!checkString(n)) {
      throw Exception(
          'Expected String for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toString2(n);
  }

  double getDoubleArg(int n, {String? name, double? defaultValue}) {
    if (!checkDouble(n)) {
      throw Exception(
          'Expected double for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toDouble(n);
  }

  bool getBoolArg(int n, {String? name, bool? defaultValue}) {
    if (!checkInt(n)) {
      throw Exception(
          'Expected bool for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toBool(n);
  }

  /// Push `global[identifier]` onto the stack
  void getGlobal(Object identifier) {
    _frame.push(globals[identifier]);
  }

  /// Take value from stack and set `global[identifier]`
  void setGlobal(Object identifier) {
    globals[identifier] = _frame.pop();
  }

  void printStack() {
    print("Stack:");
    print(_frame.toString());
  }

  int? debugInstructionContext = 5;
  void printInstructions() {
    print("Instructions:");
    print(_frame.function!
        .instructionsToString(pc: _frame.pc, context: debugInstructionContext));
  }

  void printConstants() {
    print("Constants:");
    print(_frame.function!.constantsToString());
  }

  void printUpvalues() {
    print("Upvalues:");
    for (var i = 0; i < _frame.function!.upvalues.length; i++) {
      print('${_frame.function!.upvalues[i]}: ${_frame.closure!.upvalues[i]}');
    }
  }

  void printOpenUpvalues() {
    print("Open Upvalues:");
    for (final upvalue in _frame.openUpvalues.values) {
      print('${upvalue.index}: $upvalue');
    }
  }

  bool debugPrintToggle = true;

  bool debugPrintInstructions = true;
  bool debugPrintStack = true;
  bool debugPrintConstants = false;
  bool debugPrintUpvalues = false;
  bool debugPrintOpenUpvalues = false;

  void debugPrint() {
    if (debugPrintToggle) {
      if (debugPrintInstructions) {
        printInstructions();
      }
      if (debugPrintStack) {
        printStack();
      }
      if (debugPrintConstants) {
        printConstants();
      }
      if (debugPrintUpvalues) {
        printUpvalues();
      }
      if (debugPrintOpenUpvalues) {
        printOpenUpvalues();
      }
    }
  }
}

class SlangException implements Exception {
  final String message;
  final SourceLocation? location;
  SlangException(this.message, this.location);

  @override
  String toString() {
    return 'SlangException: $message at $location';
  }

  void toSlang(SlangVm vm) {
    vm.newTable();
    vm.pushValue(-1);
    vm.push("message");
    vm.push(message);
    vm.setTable();
    if (location != null) {
      vm.pushValue(-1);
      vm.push("location");
      vm.newTable();
      vm.pushValue(-1);
      vm.push("line");
      vm.push(location!.line);
      vm.setTable();
      vm.pushValue(-1);
      vm.push("column");
      vm.push(location!.column);
      vm.setTable();
      vm.pushValue(-1);
      vm.push("origin");
      vm.push(location!.origin);
      vm.setTable();
      vm.setTable();
    }
  }
}
