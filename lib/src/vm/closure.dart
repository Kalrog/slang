import 'package:slang/slang.dart';
import 'package:slang/src/vm/function_prototype.dart';

class UpvalueHolder {
  final int index;
  SlangStackFrame? stack;
  Object? value;

  UpvalueHolder.value(this.value) : index = 0;

  UpvalueHolder.stack(this.stack, this.index);

  Object? get() {
    return stack != null ? stack![index] : value;
  }

  void set(Object? value) {
    if (stack != null) {
      stack![index] = value;
    } else {
      this.value = value;
    }
  }

  void migrate() {
    if (stack != null) {
      value = stack![index];
      stack = null;
    }
  }

  @override
  String toString() {
    return 'UpvalueHolder{index: $index, inStack: ${stack != null}, value: ${get()}}';
  }
}

typedef DartFunction = bool Function(SlangVm vm);

class Closure {
  final FunctionPrototype? prototype;
  final DartFunction? dartFunction;
  final List<UpvalueHolder?> upvalues;

  Closure.slang(FunctionPrototype prototype)
      : dartFunction = null,
        prototype = prototype,
        upvalues = List.filled(prototype.upvalues.length, null);

  Closure.dart(DartFunction dartFunction)
      : dartFunction = dartFunction,
        prototype = null,
        upvalues = [];

  @override
  String toString() {
    if (dartFunction != null) {
      return 'Closure{dartFunction}';
    } else {
      return 'Closure{prototype, upvalues: $upvalues}';
    }
  }
}

class SlangArgumentCountError {
  final String functionName;
  final int expected;
  final int got;

  SlangArgumentCountError(this.functionName, this.expected, this.got);

  @override
  String toString() {
    return 'SlangArgumentError{functionName: $functionName, expected: $expected, got: $got}';
  }
}

class SlangArgumentTypeError {
  final String functionName;
  final Type expected;
  final Type got;

  SlangArgumentTypeError(this.functionName, {required this.expected, required this.got});

  @override
  String toString() {
    return 'SlangArgumentError{functionName: $functionName, expected: $expected, got: $got}';
  }
}

class SlangTypeError {
  final Type expected;
  final Type got;
  SlangTypeError({required this.expected, required this.got});

  @override
  String toString() {
    return 'SlangTypeError{expected: $expected, got: $got}';
  }
}
