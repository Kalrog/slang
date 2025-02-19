import 'package:slang/slang.dart';
import 'package:slang/src/vm/function_prototype.dart';

class UpvalueHolder {
  final int index;
  SlangStackFrame? stack;
  Object? value;

  UpvalueHolder.value(this.value) : index = 0;

  UpvalueHolder(this.stack, this.index);

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
}

typedef DartFunction = Object? Function(SlangVm vm, List<Object?> args);

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
}
