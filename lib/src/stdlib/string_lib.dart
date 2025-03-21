import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/package_lib.dart';

class SlangStringLib {
  static const stringLib = """
  return module{
    func join(t,sep){
      local result = ""
      local first  = true
      for (local s in values(t)){
        if(type(s) != "string"){
          error("expected string, got ",type(s))
        }
        if(first){
          result = s 
          first = false
        }else{
          result = concat(result,sep,s)
        }
      }
    }
  }
""";

  static void register(SlangVm vm) {
    SlangPackageLib.preloadModule(vm, "slang/string", stringLib);
  }
}
