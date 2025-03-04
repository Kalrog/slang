import 'package:slang/slang.dart';
import 'package:slang/src/vm/closure.dart';

class SlangStdLib {
  static Map<String, DartFunction> functions = {
    "print": _print,
    "compile": _compile,
    "type": _type,
    "assert": _assert,
  };

  static Object? _print(SlangVm vm, List<Object?> args) {
    // print(args[0]);
    final sb = StringBuffer();
    for (var arg in args) {
      sb.write(arg);
    }
    print(sb.toString());
    return null;
  }

  static Object? _compile(SlangVm vm, List<Object?> args) {
    vm.compile(args[0] as String);
    return null;
  }

  static Object? _type(SlangVm vm, List<Object?> args) {
    if (args.isEmpty) {
      return "null";
    }
    return args[0].runtimeType.toString();
  }

  static Object? _assert(SlangVm vm, List<Object?> args) {
    if (args.isEmpty) {
      throw ArgumentError("assert requires at least one argument");
    }
    final assertion = args[0];
    final message = args.length > 1 ? args[1] : "assertion failed";
    if (assertion == null || assertion == false) {
      throw ArgumentError(message);
    }
    return null;
  }

  static void register(SlangVm vm) {
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
  }
}
