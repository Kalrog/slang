import 'dart:io';

import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';

class SlangPackageLib {
  static Map<String, DartFunction> functions = {
    "require": _require,
  };

  static bool _require(SlangVm vm) {
    final packageName = vm.getStringArg(0, name: "packageName");
    vm.getGlobal('__PACKAGES');
    vm.push("loaders");
    vm.getTable();
    int i = 0;
    while (true) {
      vm.pushValue(-1);
      vm.push(i);
      vm.getTable();
      if (vm.checkNull(-1)) {
        break;
      }
      vm.push(packageName);
      vm.call(1);
      if (!vm.checkNull(-1)) {
        return true;
      }
      vm.pop();
      i++;
    }
    if (vm.mode == ExecutionMode.runDebug) {
      print("Package not found: $packageName");
    }
    return false;
  }

  static bool _preloadedPackages(SlangVm vm) {
    final packageName = vm.getStringArg(0, name: "packageName");
    vm.getGlobal('__PACKAGES');
    vm.push("preloaded");
    vm.getTable();
    vm.push(packageName);
    vm.getTable();
    return true;
  }

  /// Searches for files named `packageName.slang` in the search paths
  /// and loads the first one found.
  static bool _searchPath(SlangVm vm) {
    final packageName = vm.getStringArg(0, name: "packageName");
    vm.getGlobal('__PACKAGES');
    vm.push("searchPaths");
    vm.getTable();
    int i = 0;
    while (true) {
      vm.pushValue(-1);
      vm.push(i);
      vm.getTable();
      if (vm.checkNull(-1)) {
        break;
      }
      final searchPath = vm.toString2(-1);
      //combine with package name and check if it exists
      final path = "$searchPath/$packageName.slang";
      final file = File(path);
      if (file.existsSync()) {
        final code = file.readAsStringSync();
        vm.compile(code, origin: packageName);
        vm.call(0);
        vm.getGlobal("__PACKAGES");
        vm.push("preloaded");
        vm.getTable();
        vm.push(packageName);
        vm.pushValue(-3);
        vm.setTable();
        return true;
      }
      vm.pop();
      i++;
    }
    return false;
  }

  /// compiles the given string and preloads it into the module enviromnet
  static preloadModule(SlangVm vm, String moduleName, String code) {
    vm.compile(code, origin: moduleName);
    vm.call(0);
    vm.getGlobal("__PACKAGES");
    vm.push("preloaded");
    vm.getTable();
    vm.push(moduleName);
    vm.pushValue(-3);
    vm.setTable();
    vm.pop();
  }

  /// take any value and loads it into the module enviromnet
  static preloadModuleValue(SlangVm vm, String moduleName) {
    vm.getGlobal("__PACKAGES");
    vm.push("preloaded");
    vm.getTable();
    vm.push(moduleName);
    vm.pushValue(-3);
    vm.setTable();
    vm.pop();
  }

  static void register(SlangVm vm) {
    _initPackagesTable(vm);
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
  }

  static void _initPackagesTable(SlangVm vm) {
    vm.newTable(0, 0);

    vm.pushValue(-1);
    vm.push("loaders");
    vm.newTable(0, 0);
    vm.pushValue(-1);
    vm.push(0);
    vm.pushDartFunction(_preloadedPackages);
    vm.setTable();
    vm.pushValue(-1);
    vm.push(1);
    vm.pushDartFunction(_searchPath);
    vm.setTable();
    vm.setTable();

    vm.pushValue(-1);
    vm.push("preloaded");
    vm.newTable(0, 0);
    vm.setTable();

    vm.pushValue(-1);
    vm.push("searchPaths");
    final searchPaths = ["."];
    vm.newTable(0, 0);
    for (int i = 0; i < searchPaths.length; i++) {
      vm.pushValue(-1);
      vm.push(i);
      vm.push(searchPaths[i]);
      vm.setTable();
    }
    vm.setTable();

    vm.setGlobal("__PACKAGES");
  }
}
