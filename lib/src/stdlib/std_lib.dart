import 'dart:io';

import 'package:slang/slang.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';

class SlangStdLib {
  static Map<String, DartFunction> functions = {
    "print": _print,
    "compile": _compile,
    "assert": _assert,
    "append": _append,
    "remove": _remove,
    "keys": _keys,
    "values": _values,
    "entries": _entries,
    "concat": _concat,
    "pcall": _pcall,
    "error": _error,
    "len": _len,
    "type": _type,
  };

  static String slangFunctions = '''
local vm = require("slang/vm");
local table = require("slang/table");

func module(mfunc){
  local m = {};
  m.meta = {__index:_ENV};
  vm.setUpvalue(mfunc,"_ENV", m);
  mfunc();
  m.meta.__index = null;
  return m;
}

func run(rfunc){
  return rfunc();
}
''';

  static bool _print(SlangVm vm) {
    int nargs = vm.getTop();
    // print(args[0]);
    final sb = StringBuffer();
    for (int i = 0; i < nargs; i++) {
      sb.write(vm.toString2(i));
    }
    //todo: make this work in browser
    stdout.write(sb.toString());
    return false;
  }

  static bool _compile(SlangVm vm) {
    final code = vm.toString2(0);
    vm.compile(code);
    return true;
  }

  static bool _assert(SlangVm vm) {
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

  static bool _remove(SlangVm vm) {
    if (!vm.checkTable(0)) {
      return false;
    }
    final table = vm.toAny(0) as SlangTable;
    final key = vm.toAny(1) as Object;
    table.remove(key);
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
    final table = (vm.toAny(0) as SlangTable?) ?? SlangTable();
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

  static bool _entries(SlangVm vm) {
    final table = (vm.toAny(0) as SlangTable?) ?? SlangTable();
    final keys = table.keys;
    int i = 0;
    vm.pushDartFunction((SlangVm vm) {
      if (i < keys.length) {
        final key = keys[i];
        final slangTable = SlangTable();
        slangTable[0] = key;
        slangTable[1] = table[key];
        vm.push(slangTable);
        i++;
        return true;
      } else {
        return false;
      }
    });
    return true;
  }

  static bool _concat(SlangVm vm) {
    if (vm.checkString(0)) {
      //build string
      var sb = StringBuffer();
      for (int i = 1; i < vm.getTop(); i++) {
        sb.write(vm.toString2(i));
      }
      vm.push(sb.toString());
      return true;
    } else if (vm.checkTable(0)) {
      final table = SlangTable();
      for (int i = 0; i < vm.getTop(); i++) {
        final value = vm.toAny(i) as SlangTable;
        table.addAll(value);
      }
      vm.push(table);
      return true;
    } else {
      throw ArgumentError("concat requires a table or string");
    }
    // final sb = StringBuffer();
    // for (int i = 0; i < vm.getTop(); i++) {
    //   sb.write(vm.toString2(i));
    // }
    // vm.push(sb.toString());
    return true;
  }

  static bool _pcall(SlangVm vm) {
    final nargs = vm.getTop();
    if (nargs < 1) {
      throw ArgumentError("pcall requires at least one argument");
    }
    vm.pCall(nargs - 1);
    return true;
  }

  static bool _error(SlangVm vm) {
    final sb = StringBuffer();
    for (int i = 0; i < vm.getTop(); i++) {
      sb.write(vm.toString2(i));
    }
    final message = sb.toString();
    vm.error(message);
    return false;
  }

  static bool _len(SlangVm vm) {
    if (vm.checkTable(0)) {
      final table = vm.toAny(0) as SlangTable;
      vm.push(table.length);
    } else if (vm.checkString(0)) {
      final str = vm.toAny(0) as String;
      vm.push(str.length);
    } else {
      throw ArgumentError("len requires a table or string");
    }
    return true;
  }

  static bool _type(SlangVm vm) {
    vm.type();
    return true;
  }

  static void register(SlangVm vm) {
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
    vm.compile(slangFunctions, origin: "slang/std");
    vm.call(0);
  }
}
