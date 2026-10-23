import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/package_lib.dart';

class SlangStringLib {
  static Map<String, DartFunction> functions = {
    "join": _join,
    "substring": _substring,
  };
//   static const stringLib = """
//   return module{
//     func join(t,sep){
//       local result = ""
//       local first  = true
//       for (local s in values(t)){
//         if(type(s) != "string"){
//           error("expected string, got ",type(s))
//         }
//         if(first){
//           result = s
//           first = false
//         }else{
//           result = concat(result,sep,s)
//         }
//       }
//     }
//   }
// """;

  static bool _join(SlangVm vm) {
    final t = vm.toAny(0) as SlangTable;
    final sep = vm.getStringArg(1, name: "seperator", defaultValue: " ");
    final result = StringBuffer();
    bool first = true;
    for (final s in t.values) {
      if (s is! String) {
        vm.error("expected string, got $s");
      }
      if (first) {
        result.write(s);
        first = false;
      } else {
        result.write(sep);
        result.write(s);
      }
    }
    vm.push(result.toString());
    return true;
  }

  static bool _substring(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    final start = vm.getIntArg(1, name: "start", defaultValue: 0);
    final end = vm.getIntArg(2, name: "end", defaultValue: str.length);
    vm.push(str.substring(start, end));
    return true;
  }

  static void register(SlangVm vm) {
    vm.newTable();
    for (final entry in functions.entries) {
      vm.pushStack(-1);
      vm.push(entry.key);
      vm.pushDartFunction(entry.value);
      vm.setTable();
    }
    SlangPackageLib.preloadModuleValue(vm, "slang/string");
  }
}
