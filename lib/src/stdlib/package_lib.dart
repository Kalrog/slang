import 'package:slang/slang.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';

class SlangPackageLib {
  static Map<String, DartFunction> functions = {
    "require": _require,
  };

  static Object? _getPackageFromLoadedPackages(SlangVm vm, List args) {
    if (args.length != 1) {
      throw SlangArgumentCountError('require_loader_preloaded', 1, args.length);
    }
    if (args[0] is! String) {
      throw SlangArgumentTypeError('require_loader_preloaded',
          expected: String, got: args[0].runtimeType);
    }
    var package = args[0] as String;
    final loaded = (vm.globals['__LOADED_PACKAGES'] as SlangTable).toMap().cast<String, Closure>();
    return loaded[package];
  }

  static Object? _require(SlangVm vm, List args) {
    if (args.length != 1) {
      throw SlangArgumentCountError('require', 1, args.length);
    }
    if (args[0] is! String) {
      throw SlangArgumentTypeError('require', expected: String, got: args[0].runtimeType);
    }
    final packageName = args[0] as String;
    vm.push(vm.globals['__PACKAGE_LOADERS']);
    int i = 0;
    while (true) {
      vm.pushValue(-1);
      vm.pushValue(i);
      vm.getTable();
      vm.push(packageName);
      
      vm.call(1);
      final package = vm.to<Object?>(-1);
      if (package != null) {
        return package;
      }
    }
  }

  static void register(SlangVm vm) {
    for (var entry in functions.entries) {
      vm.registerDartFunction(entry.key, entry.value);
    }
  }
}
