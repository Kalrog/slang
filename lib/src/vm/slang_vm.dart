import 'dart:io';

import 'package:slang/src/compiler.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class SlangStackFrame {
  int _pc = 0;
  late List stack = [];
  SlangStackFrame? parent;
  FunctionPrototype? function;
  SlangStackFrame([this.function, this.parent]);

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
    stack.addAll(List.filled(top - stack.length, null));
  }
}

enum BinOpType { add, sub, mul, div, mod }

enum RelOpType {
  lt,
  leq,
  eq,
}

enum UnOpType { neg, not }

class SlangVm {
  SlangStackFrame frame = SlangStackFrame();

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

  void compile(String code) {
    FunctionPrototype prototype = compileSource(code);
    frame.push(prototype);
  }

  void call({bool step = false}) {
    final prototype = frame.pop();
    if (prototype is! FunctionPrototype) {
      throw Exception('Expected FunctionPrototype');
    }
    _pushStack(prototype);
    frame.setTop(prototype.maxStackSize);
    try {
      _runSlangFunction(step: step);
    } catch (e) {
      print(e);
      print(frame);
    }
  }

  void _pushStack([FunctionPrototype? function]) {
    frame = SlangStackFrame(function, frame);
  }

  void _popStack() {
    frame = frame.parent!;
  }

  void addPc(int n) {
    frame.addPc(n);
  }

  void jump(int n) {
    addPc(n);
  }

  void _runSlangFunction({bool step = false}) {
    while (true) {
      final instruction = frame.currentInstruction;
      final op = instruction.op;
      if (step) {
        /// Print the current stack and wait for the user to press enter
        // print(frame.toString());
        debugPrint();
        //wait for input
        stdin.readLineSync();
      }

      op.execute(this, instruction);
      addPc(1);
      if (op.name == OpCodeName.returnOp) {
        break;
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

  void debugPrint() {
    print(frame.function!.toString(pc: frame.pc));
    print(frame.toString());
  }
}
