import 'package:slang/src/slang_vm.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm.dart';

/// [UpvalueHolder]s are used to reference variables in the enclosing scope of a closure and to
/// capture(store) them when the scope is closed and the variable is destroyed, so the closure can continue
/// to access the variables after the scope has been destroyed.
class UpvalueHolder {
  /// [index] is the index of the variable in the enclosing scope.
  final int index;

  /// [stack] is the stack frame in which the variable is located.
  SlangStackFrame? stack;

  /// [value] contains the value of the variable if the variable is not on the stack anymore.
  Object? value;

  /// Creates a new [UpvalueHolder] that contains an already captured value outside of the stack.
  UpvalueHolder.value(this.value) : index = 0;

  /// Creates a new [UpvalueHolder] that references a variable on the stack.
  UpvalueHolder.stack(this.stack, this.index);

  /// Returns the value of the upvalue. Either by reading it from the stack or from the [value] field.
  Object? get() {
    return stack != null ? stack![index] : value;
  }

  /// Sets the value of the upvalue. Either by writing it to the stack or to the [value] field.
  void set(Object? value) {
    if (stack != null) {
      stack![index] = value;
    } else {
      this.value = value;
    }
  }

  /// Migrates the upvalue from the stack to the [value] field.
  /// The Slang VM ensures that this is called right before the scope that containing the variable
  /// referenced by this upvalue is destroyed.
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

/// A closure is a function that captures the environment in which it was created.
///
/// In Slang, all functions are closures, even if they don't capture any variables.
/// Closures capture variables by creating upvalues, which are references to variables in the enclosing scope.
/// When a closure leaves the scope in which it was created, it migrates the upvalues from their
/// location on the stack into the [UpvalueHolder]s. The Slang VM ensures, that closures that reference
/// the same instance of a variable on the stack, also get the same [UpvalueHolder] instance.
///
/// Closures can be either Slang functions or Dart functions.
/// Dart functions are used for built-in functions, like `print` or `assert` and for custom functions
/// that are implemented in Dart.
class Closure {
  /// [prototype] is the function prototype of a Slang function.
  /// it contains the bytecode and other information necessary for loading a Slang function into the VM.
  final FunctionPrototype? prototype;

  /// [dartFunction] is a Dart function that is called when the closure is executed.
  final DartFunction? dartFunction;

  /// [upvalues] is a list of [UpvalueHolder]s that the closure uses to reference variables in the
  /// enclosing scope and to capture them when it leaves the scope.
  final List<UpvalueHolder?> upvalues;

  /// true if the closure is a Dart function.
  bool get isDart => dartFunction != null;

  /// true if the closure is a Slang function.
  bool get isSlang => prototype != null;

  /// Creates a new closure for a Slang function.
  Closure.slang(FunctionPrototype prototype)
      : dartFunction = null,
        prototype = prototype,
        upvalues = List.filled(prototype.upvalues.length, null);

  /// Creates a new closure for a Dart function.
  Closure.dart(DartFunction dartFunction)
      : dartFunction = dartFunction,
        prototype = null,
        upvalues = [];

  @override
  String toString() {
    if (dartFunction != null) {
      return 'Closure{dartFunction}';
    } else {
      return 'Closure{prototype}';
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
