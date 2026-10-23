import 'package:slang/src/slang_vm.dart';

extension SlangVmHelpers on SlangVm {
  void setField(int index, dynamic name) {
    pushStack(index);
    push(name);
    pushStack(-3);
    setTable();
    pop();
  }
}
