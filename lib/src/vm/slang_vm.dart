import 'package:slang/src/compiler.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class SlangStackFrame {
  late List stack = [];
  SlangStackFrame? parent;
  FunctionPrototype? function;
  SlangStackFrame([this.function, this.parent]);

  int absIndex(int index) {
    if (index < 0) {
      return stack.length + index + 1;
    }
    return index;
  }

  void push(dynamic value) {
    stack.add(value);
  }

  dynamic pop() {
    return stack.removeLast();
  }

  operator [](int index) {
    final absIdx = absIndex(index);
    if (absIdx >= stack.length || absIdx < 0) {
      return null;
    }
    return stack[index];
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

enum UnOpType { neg }

class SlangVm {
  SlangStackFrame frame = SlangStackFrame();

  void execUnOp(UnOpType op) {
    final a = frame.pop();
    switch (op) {
      case UnOpType.neg:
        frame.push(-a);
        break;
    }
  }

  void execBinOp(BinOpType op) {
    final b = frame.pop();
    final a = frame.pop();
    switch (op) {
      case BinOpType.add:
        frame.push(a + b);
        break;
      case BinOpType.sub:
        frame.push(a - b);
        break;
      case BinOpType.mul:
        frame.push(a * b);
        break;
      case BinOpType.div:
        frame.push(a / b);
        break;
      case BinOpType.mod:
        frame.push(a % b);
        break;
    }
  }

  void push(dynamic value) {
    frame.push(value);
  }

  void pushValue(int index) {
    frame.push(frame[index]);
  }

  void pop() {
    frame.pop();
  }

  void replace(int index) {
    frame[index] = frame.pop();
  }

  void loadConstant(int index) {
    final k = frame.function!.constants[index];
    frame.push(k);
  }

  void loadRegisterOrConstant(int index) {
    if (index & 0x100 != 0) {
      index = index & 0xFF;
      loadConstant(index);
    } else {
      pushValue(index);
    }
  }

  void newTable([int nArray = 0, int nHash = 0]) {
    frame.push(SlangTable(nArray, nHash));
  }

  void setTable() {
    final value = frame.pop();
    final key = frame.pop();
    final table = frame[-1];
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable');
    }
    table[key] = value;
  }

  void getTable() {
    final key = frame.pop();
    final table = frame[-1];
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable');
    }
    frame.push(table[key]);
  }

  void compile(String code) {
    FunctionPrototype prototype = compileSource(code);
    frame.push(prototype);
  }

  void call() {
    final prototype = frame.pop();
    if (prototype is! FunctionPrototype) {
      throw Exception('Expected FunctionPrototype');
    }
    _pushStack(prototype);
    frame.setTop(prototype.maxStackSize);
    _runSlangFunction(prototype);
  }

  void _pushStack([FunctionPrototype? function]) {
    frame = SlangStackFrame(function, frame);
  }

  void _popStack() {
    frame = frame.parent!;
  }

  void _runSlangFunction(FunctionPrototype prototype) {
    for (var i = 0; i < prototype.instructions.length; i++) {
      final instruction = prototype.instructions[i];
      final op = instruction.op;
      op.execute(this, instruction);
    }
  }

  void returnOp(int n) {
    final result = frame[n];
    _popStack();
    frame.push(result);
  }

  int takeInt(int n) {
    return frame[n] as int;
  }

  String takeString(int n) {
    return frame[n] as String;
  }
}
