import 'package:slang/slang.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';

class SlangStdLib {
  static Map<String, DartFunction> functions = {
    "print": _print,
    "compile": _compile,
    "type": _type,
    "assert": _assert,
    "setMeta": _setMeta,
    "getMeta": _getMeta,
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
      throw Exception(message);
    }
    return null;
  }

  static Object? _setMeta(SlangVm vm, List<Object?> args) {
    if (args.length < 2) {
      throw ArgumentError("setMeta requires at least two arguments");
    }
    final table = args[0] as SlangTable;
    final value = args[1] as SlangTable?;
    table.metatable = value;
    return null;
  }

  static Object? _getMeta(SlangVm vm, List<Object?> args) {
    if (args.isEmpty) {
      throw ArgumentError("getMeta requires at least one argument");
    }
    final table = args[0] as SlangTable;
    return table.metatable;
  }

  static void register(SlangVm vm) {
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
  }
}
