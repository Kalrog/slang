import 'package:slang/slang.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';

class SlangStdLib {
  static Map<String, DartFunction> functions = {
    "print": _print,
    "compile": _compile,
    "assert": _assert,
    "append": _append,
    "keys": _keys,
    "values": _values,
  };

  static bool _print(SlangVm vm) {
    int nargs = vm.getTop();
    // print(args[0]);
    final sb = StringBuffer();
    for (int i = 0; i <= nargs; i++) {
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

  static bool _append(SlangVm vm) {
    vm.appendTable();
    return false;
  }

  static bool _keys(SlangVm vm) {
    if (!vm.checkTable(0)) {
      return false;
    }
    final table = vm.toAny(0) as SlangTable;
    final keys = table.keys;
    int i = 0;
    vm.pushDartFunction((SlangVm vm) {
      if (i < keys.length) {
        vm.push(keys[i]);
        i++;
        return true;
      } else {
        return false;
      }
    });
    return true;
  }

  static bool _values(SlangVm vm) {
    if (!vm.checkTable(0)) {
      return false;
    }
    final table = vm.toAny(0) as SlangTable;
    final keys = table.keys;
    int i = 0;
    vm.pushDartFunction((SlangVm vm) {
      if (i < keys.length) {
        vm.push(table[keys[i]]);
        i++;
        return true;
      } else {
        return false;
      }
    });
    return true;
  }

  static void register(SlangVm vm) {
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
  }
}
