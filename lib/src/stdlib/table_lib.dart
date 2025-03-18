import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/package_lib.dart';

class SlangTableLib {
  static const tableLib = """
  local m = {}
  func m.contains(t, value){
    for (local k in values(t)){
      if (t[k] == value){
        return true
      }
    }
  }

  func m.map(t, f){
    local result = {}
    for (local k in values(t)){
      result[k] = f(t[k])
    }
    return result
  } 

  func m.filter(t, f){
    local result = {}
    for (local k in values(t)){
      if (f(t[k])){
        result[k] = t[k]
      }
    }
    return result
  }

  func m.fold(t, init, f){
    local result = init
    for (local k in values(t)){
      result = f(result, t[k])
    }
    return result
  }
  return m
""";

  static void register(SlangVm vm) {
    SlangPackageLib.preloadModule(vm, "slang/table", tableLib);
  }
}
