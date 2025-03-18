import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';

class SlangThreadsLib {
  static Map<String, DartFunction> functions = {
    "create": _create,
    "resume": _resume,
    "yield": _yield,
    "state": _state,
  };

  static bool _create(SlangVm vm) {
    vm.createThread();
    return true;
  }

  static bool _resume(SlangVm vm) {
    vm.resume(vm.getTop() - 1);
    return true;
  }

  static bool _yield(SlangVm vm) {
    vm.yield();
    return false;
  }

  static bool _state(SlangVm vm) {
    final thread = vm.toAny(-1) as SlangVm;
    vm.push(thread.state.name);
    return true;
  }

  static void register(SlangVm vm) {
    vm.newTable(0, 0);
    for (var entry in functions.entries) {
      vm.pushValue(-1);
      vm.push(entry.key);
      vm.pushDartFunction(entry.value);
      vm.setTable();
    }
    SlangPackageLib.preloadModuleValue(vm, "slang/thread");
  }
}
