import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';

class SlangVmLib {
  static Map<String, DartFunction> functions = {
    "setUpvalue": _setUpvalue,
    "getUpvalue": _getUpvalue,
  };

  /// setUpvalue(closure,name,value)
  /// replaces the upvalue holder for upvalue with name `name`
  /// of closure with a new upvalue holder containing the value `value`.
  static bool _setUpvalue(SlangVm vm) {
    final nargs = vm.getTop();
    if (nargs != 3) {
      throw ArgumentError("module expects exactly one argument");
    }
    final closure = vm.toAny(0) as Closure;
    final name = vm.getStringArg(1, name: "name");
    final value = vm.toAny(2);
    final upvalueDefs = closure.prototype!.upvalues;
    for (var i = 0; i < upvalueDefs.length; i++) {
      final upvalueDef = upvalueDefs[i];
      if (upvalueDef.name == name) {
        closure.upvalues[i] = UpvalueHolder.value(value);
        return false;
      }
    }
    return false;
  }

  /// getUpvalue(closure,name)
  /// returns the value of the upvalue with name `name` of closure.
  /// If the upvalue does not exist, it returns nil.
  static bool _getUpvalue(SlangVm vm) {
    final nargs = vm.getTop();
    if (nargs != 2) {
      throw ArgumentError("module expects exactly one argument");
    }
    final closure = vm.toAny(0) as Closure;
    final name = vm.getStringArg(1, name: "name");
    final upvalueDefs = closure.prototype!.upvalues;
    for (var i = 0; i < upvalueDefs.length; i++) {
      final upvalueDef = upvalueDefs[i];
      if (upvalueDef.name == name) {
        final upvalue = closure.upvalues[i];
        vm.push(upvalue?.get());
        return true;
      }
    }
    vm.push(null);
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
    SlangPackageLib.preloadModuleValue(vm, "slang/vm");
  }
}
