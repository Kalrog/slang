import 'dart:io';

import 'package:slang/slang.dart';

class SlangStdLib {
  static Map<String, DartFunction> functions = {
    "args": _args,
    "print": _print,
    "readLine": _readLine,
    "open": _open,
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
    "setRaw": _setRaw,
    "getRaw": _getRaw,
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

  static bool _args(SlangVm vm) {
    final args = SlangTable();
    for (String arg in vm.args) {
      args.add(arg);
    }
    vm.push(args);
    return true;
  }

  static bool _print(SlangVm vm) {
    int nargs = vm.getTop();
    // print(args[0]);
    final sb = StringBuffer();
    for (int i = 0; i < nargs; i++) {
      sb.write(vm.toString2(i));
    }
    //todo: make this work in browser
    // stdout.write(sb.toString());
    vm.stdout.add(sb.toString().codeUnits);
    return false;
  }

  static bool _readLine(SlangVm vm) {
    vm.push(vm.stdin.readLineSync());
    return true;
  }

  static final SlangTable _fileMetaTable = SlangTable();

  static void _prepareFileMetatable(SlangVm vm) {
    Map<String, DartFunction> fileFunctions = {
      "read": _readStringFile,
      "write": _writeStringFile,
      "readBytes": _readBytesFile,
      "writeBytes": _writeBytesFile,
      "close": _closeFile,
    };
    vm.newTable();
    for (var entry in fileFunctions.entries) {
      vm.pushStack(-1);
      vm.push(entry.key);
      vm.pushDartFunction(entry.value);
      vm.setTable();
    }
    final indexTable = vm.toAny(-1) as SlangTable;
    vm.pop();
    _fileMetaTable['__index'] = indexTable;
  }

  static bool _open(SlangVm vm) {
    final path = vm.getStringArg(0, name: "path");
    final modeStr = vm.getStringArg(1, name: "mode", defaultValue: "r");

    FileMode mode = FileMode.read;
    if (modeStr.contains("r") && modeStr.contains("w")) {
      mode = FileMode.write;
    } else if (modeStr.contains("r")) {
      mode = FileMode.read;
    } else if (modeStr.contains("w")) {
      mode = FileMode.writeOnly;
    }
    if (modeStr.contains("a")) {
      switch (mode) {
        case FileMode.read:
          mode = FileMode.append;
          break;
        case FileMode.write:
          mode = FileMode.append;
          break;
        case FileMode.writeOnly:
          mode = FileMode.writeOnlyAppend;
          break;
        default:
          mode = FileMode.append;
          break;
      }
    }

    final file = File(path);
    if (!file.existsSync()) {
      file.createSync(recursive: true);
    }
    final raf = file.openSync(mode: mode);
    vm.push(raf);
    vm.pushStack(-1);
    vm.push(_fileMetaTable);
    vm.setMetaTable();
    return true;
  }

  static bool _readStringFile(SlangVm vm) {
    final file = vm.getUserdataArg<RandomAccessFile>(0, name: "file");
    final length =
        vm.getIntArg(1, name: "length", defaultValue: file.lengthSync());
    final buffer = file.readSync(length);
    vm.push(String.fromCharCodes(buffer));
    return true;
  }

  static bool _writeStringFile(SlangVm vm) {
    final file = vm.getUserdataArg<RandomAccessFile>(0, name: "file");
    final str = vm.getStringArg(1, name: "str");
    file.writeStringSync(str);
    return false;
  }

  static bool _readBytesFile(SlangVm vm) {
    final file = vm.getUserdataArg<RandomAccessFile>(0, name: "file");
    final length =
        vm.getIntArg(1, name: "length", defaultValue: file.lengthSync());
    final buffer = file.readSync(length);
    vm.push(buffer);
    return true;
  }

  static bool _writeBytesFile(SlangVm vm) {
    final file = vm.getUserdataArg<RandomAccessFile>(0, name: "file");
    final buffer = vm.toAny(1) as List<int>;
    file.writeFromSync(buffer);
    return false;
  }

  static bool _closeFile(SlangVm vm) {
    final file = vm.getUserdataArg<RandomAccessFile>(0, name: "file");
    file.closeSync();
    return false;
  }

  static bool _compile(SlangVm vm) {
    final code = vm.toString2(0);
    vm.compile(code);
    return true;
  }

  static bool _assert(SlangVm vm) {
    final assertion = vm.toBool(0);
    // final message = vm.getTop() > 1 ? vm.toString2(1) : "assertion failed";
    // if (!assertion) {
    //   throw Exception(message);
    // }
    String message = "";
    for (int i = 1; i < vm.getTop(); i++) {
      message += vm.toString2(i);
    }
    if (message.isEmpty) {
      message = "assertion failed";
    }
    if (!assertion) {
      vm.error(message);
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
    vm.push(table.remove(key));
    return true;
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
      for (int i = 0; i < vm.getTop(); i++) {
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
    vm.pCall(nargs - 1, then: (SlangVm vm) {
      return true;
    });
    return false;
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

  static bool _setRaw(SlangVm vm) {
    vm.setTableRaw();
    return false;
  }

  static bool _getRaw(SlangVm vm) {
    vm.getTableRaw();
    return true;
  }

  /// Register all standard library functions in the given vm.
  static void register(SlangVm vm) {
    _prepareFileMetatable(vm);
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
    vm.compile(slangFunctions, origin: "slang/std");
    vm.call(0);
    vm.run();
  }
}
