import 'dart:io';

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

  int get currentInstruction => function!.instructions[_pc];

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

  void get top => stack.length;

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
  SlangStackFrame frame = SlangStackFrame();
  SlangTable globals = SlangTable();
  ExecutionMode mode = ExecutionMode.run;

  void execUnOp(UnOpType op) {
    final a = frame.pop();
    switch (op) {
      case UnOpType.neg:
        frame.push(-a);
      case UnOpType.not:
        frame.push(!a);
    }
  }

  void execBinOp(BinOpType op) {
    final b = frame.pop();
    final a = frame.pop();
    switch (op) {
      case BinOpType.add:
        frame.push(a + b);
      case BinOpType.sub:
        frame.push(a - b);
      case BinOpType.mul:
        frame.push(a * b);
      case BinOpType.div:
        frame.push(a / b);
      case BinOpType.mod:
        frame.push(a % b);
    }
  }

  void execRelOp(RelOpType op) {
    final b = frame.pop();
    final a = frame.pop();
    switch (op) {
      case RelOpType.lt:
        frame.push(a < b);
      case RelOpType.leq:
        frame.push(a <= b);
      case RelOpType.eq:
        frame.push(a == b);
    }
  }

  void push(dynamic value) {
    frame.push(value);
  }

  void pushValue(int index) {
    frame.push(frame[index]);
  }

  void pop([int keep = 0, int pop = 1]) {
    final popped = frame.pop(pop + keep);
    if (keep > 0) {
      final kept = popped.sublist(pop);
      frame.stack.addAll(kept);
    }
  }

  void replace(int index) {
    frame[index] = frame.pop();
  }

  void loadConstant(int index) {
    final k = frame.function!.constants[index];
    frame.push(k);
  }

  void newTable([int nArray = 0, int nHash = 0]) {
    frame.push(SlangTable(nArray, nHash));
  }

  void setTable() {
    final value = frame.pop();
    final key = frame.pop();
    final table = frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    table[key] = value;
  }

  void getTable() {
    final key = frame.pop();
    final table = frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    frame.push(table[key]);
  }

  void setUpvalue(int index) {
    final value = frame.pop();
    final upvalue = frame.closure!.upvalues[index];
    upvalue!.set(value);
  }

  void getUpvalue(int index) {
    final upvalue = frame.closure!.upvalues[index];
    frame.push(upvalue!.get());
  }

  void closeUpvalues(int fromIndex) {
    frame.openUpvalues.removeWhere((_, upvalue) {
      if (upvalue.index >= fromIndex) {
        upvalue.migrate();
        return true;
      }
      return false;
    });
  }

  void compile(String code) {
    FunctionPrototype prototype = compileSource(code);
    Closure closure = Closure.slang(prototype);
    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    frame.push(closure);
  }

  void loadClosure(int index) {
    final prototype = frame.function!.children[index];
    Closure closure = Closure.slang(prototype);
    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    for (final (index, uv) in prototype.upvalues.indexed) {
      if (frame.openUpvalues[uv.index] != null) {
        closure.upvalues[index] = frame.openUpvalues[uv.index];
      } else if (uv.isLocal) {
        closure.upvalues[index] = UpvalueHolder.stack(frame, uv.index);
        frame.openUpvalues[uv.index] = closure.upvalues[index]!;
      } else {
        closure.upvalues[index] = frame.closure!.upvalues[uv.index];
      }
    }
    frame.push(closure);
  }

  void call(int nargs) {
    var args = frame.pop(nargs) ?? [];
    if (args != List) {
      args = [args];
    }
    final closure = frame.pop();
    if (closure is! Closure) {
      throw Exception('Expected FunctionPrototype');
    }
    _pushStack(closure);
    for (final arg in args) {
      frame.push(arg);
    }
    if (closure.prototype != null) {
      frame.setTop(closure.prototype!.maxStackSize);
      try {
        _runSlangFunction();
      } catch (e) {
        print(e);
        print(frame);
      }
    } else {
      final value = closure.dartFunction!(this, args);
      _popStack();
      frame.push(value);
    }
  }

  void registerDartFunction(String name, DartFunction function) {
    globals[name] = Closure.dart(function);
  }

  void _pushStack([Closure? closure]) {
    frame = SlangStackFrame(closure, frame);
  }

  void _popStack() {
    for (final upvalue in frame.openUpvalues.values) {
      upvalue.migrate();
    }
    frame = frame.parent!;
  }

  void addPc(int n) {
    frame.addPc(n);
  }

  void jump(int n) {
    addPc(n);
  }

  Set<int> breakPoints = {};
  void _runSlangFunction() {
    while (true) {
      final instruction = frame.currentInstruction;
      final op = instruction.op;

      bool brk = false;
      if (breakPoints.contains(frame.pc) && mode == ExecutionMode.runDebug) {
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

  void returnOp(int n) {
    final result = frame[n];
    _popStack();
    frame.push(result);
  }

  int toInt(int n) {
    return frame[n] as int;
  }

  String toString2(int n) {
    return frame[n] as String;
  }

  SlangTable toTable(int n) {
    return frame[n] as SlangTable;
  }

  bool toBool(int n) {
    return frame[n] == null || frame[n] == false;
  }

  // void debugPrint() {
  //   print(frame.function!.toString(pc: frame.pc));
  //   print(frame.toString());
  // }

  void printStack() {
    print("Stack:");
    print(frame.toString());
  }

  int? debugInstructionContext = 5;
  void printInstructions() {
    print("Instructions:");
    print(frame.function!
        .instructionsToString(pc: frame.pc, context: debugInstructionContext));
  }

  void printConstants() {
    print("Constants:");
    print(frame.function!.constantsToString());
  }

  void printUpvalues() {
    print("Upvalues:");
    for (var i = 0; i < frame.function!.upvalues.length; i++) {
      print('${frame.function!.upvalues[i]}: ${frame.closure!.upvalues[i]}');
    }
  }

  bool debugPrintToggle = true;

  bool debugPrintInstructions = true;
  bool debugPrintStack = true;
  bool debugPrintConstants = false;
  bool debugPrintUpvalues = false;

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
    }
  }
}
