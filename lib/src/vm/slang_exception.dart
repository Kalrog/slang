import 'package:slang/src/compiler/codegen/function_assembler.dart';
import 'package:slang/src/vm/slang_vm.dart';

class SlangException implements Exception {
  final String message;
  final SourceLocation? location;
  SlangException(this.message, this.location);

  void toSlang(SlangVmImpl vm) {
    vm.newTable();
    vm.pushValue(-1);
    vm.push("message");
    vm.push(message);
    vm.setTable();
    if (location != null) {
      vm.pushValue(-1);
      vm.push("location");
      vm.newTable();
      vm.pushValue(-1);
      vm.push("line");
      vm.push(location!.line);
      vm.setTable();
      vm.pushValue(-1);
      vm.push("column");
      vm.push(location!.column);
      vm.setTable();
      vm.pushValue(-1);
      vm.push("origin");
      vm.push(location!.origin);
      vm.setTable();
      vm.setTable();
    }
  }

  @override
  String toString() {
    return 'SlangException: $message at $location';
  }
}
