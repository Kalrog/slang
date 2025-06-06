import 'dart:io';

import 'package:slang/slang.dart';

class SlangPackageLib {
  static Map<String, DartFunction> functions = {
    "require": _require,
  };

  static bool _require(SlangVm vm) {
    final packageName = vm.getStringArg(0, name: "packageName");
    try {
      vm.getGlobal('__PACKAGES');
      vm.push("loaders");
      vm.getTable();
      int i = 0;
      while (true) {
        vm.pushStack(-1);
        vm.push(i);
        vm.getTable();
        if (vm.checkNull(-1)) {
          break;
        }
        vm.push(packageName);
        vm.call(1);
        vm.run();
        if (!vm.checkNull(-1)) {
          vm.push(1);
          vm.getTable();
          return true;
        }
        vm.pop();
        i++;
      }
      if (vm.debug.mode == DebugMode.runDebug) {
        print("Package not found: $packageName");
      }
      return false;
    } catch (e) {
      print("Error loading package: $packageName");
      rethrow;
    }
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
      vm.pushStack(-1);
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
        vm.load(code, origin: packageName);
        vm.call(0);
        vm.run();
        vm.newTable();
        vm.pushStack(-1);
        vm.push(0);
        vm.push(true);
        vm.setTable();
        vm.pushStack(-1);
        vm.push(1);
        vm.pushStack(-4);
        vm.setTable();
        vm.getGlobal("__PACKAGES");
        vm.push("preloaded");
        vm.getTable();
        vm.push(packageName);
        vm.pushStack(-3);
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
    vm.load(code, origin: moduleName);
    vm.call(0);
    vm.run();
    vm.getGlobal("__PACKAGES");
    vm.push("preloaded");
    vm.getTable();
    vm.push(moduleName);
    vm.newTable();
    vm.pushStack(-1);
    vm.push(0);
    vm.push(true);
    vm.setTable();
    vm.pushStack(-1);
    vm.push(1);
    vm.pushStack(-6);
    vm.setTable();
    vm.setTable();
    vm.pop();
  }

  /// take any value and loads it into the module enviromnet
  static preloadModuleValue(SlangVm vm, String moduleName) {
    vm.getGlobal("__PACKAGES");
    vm.push("preloaded");
    vm.getTable();
    vm.push(moduleName);
    vm.newTable();
    vm.pushStack(-1);
    vm.push(0);
    vm.push(true);
    vm.setTable();
    vm.pushStack(-1);
    vm.push(1);
    vm.pushStack(-6);
    vm.setTable();
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

    vm.pushStack(-1);
    vm.push("loaders");
    vm.newTable(0, 0);
    vm.pushStack(-1);
    vm.push(0);
    vm.pushDartFunction(_preloadedPackages);
    vm.setTable();
    vm.pushStack(-1);
    vm.push(1);
    vm.pushDartFunction(_searchPath);
    vm.setTable();
    vm.setTable();

    vm.pushStack(-1);
    vm.push("preloaded");
    vm.newTable(0, 0);
    vm.setTable();

    vm.pushStack(-1);
    vm.push("searchPaths");
    final searchPaths = ["."];
    vm.newTable(0, 0);
    for (int i = 0; i < searchPaths.length; i++) {
      vm.pushStack(-1);
      vm.push(i);
      vm.push(searchPaths[i]);
      vm.setTable();
    }
    vm.setTable();

    vm.setGlobal("__PACKAGES");
  }
}
