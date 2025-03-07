import 'package:slang/slang.dart';
import 'package:slang/src/vm/closure.dart';

class SlangStdLib {
  static Map<String, DartFunction> functions = {
    "print": _print,
    "compile": _compile,
    "assert": _assert,
  };

  static bool _print(SlangVm vm) {
    int nargs = vm.getTop();
    // print(args[0]);
    final sb = StringBuffer();
    for (int i = 0; i < nargs; i++) {
      sb.write(vm.toString2(i));
    }
    print(sb.toString());
    return false;
  }

  static bool _compile(SlangVm vm) {
    final code = vm.toString2(0);
    vm.compile(code);
    return true;
  }

  static bool _assert(SlangVm vm) {
    // if (args.isEmpty) {
    //   throw ArgumentError("assert requires at least one argument");
    // }
    // final assertion = args[0];
    // final message = args.length > 1 ? args[1] : "assertion failed";
    // if (assertion == null || assertion == false) {
    //   throw Exception(message);
    // }
    // return null;
    final assertion = vm.toBool(0);
    final message = vm.getTop() > 1 ? vm.toString2(1) : "assertion failed";
    if (!assertion) {
      throw Exception(message);
    }
    return false;
  }

  static void register(SlangVm vm) {
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
  }
}
