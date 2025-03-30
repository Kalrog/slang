import 'package:slang/slang.dart';
import 'package:test/test.dart';

class TestValue {
  int value;
  TestValue(this.value);
}

void main() {
  test("Userdata", () {
    SlangVm vm = SlangVm.create();
    vm.push(TestValue(123));
    vm.pushStack(-1);
    vm.newTable();
    vm.pushStack(-1);
    vm.push("__index");
    vm.pushDartFunction((vm) {
      final userdata = vm.getUserdataArg<TestValue>(0, name: "self");
      final key = vm.getStringArg(1, name: "key");
      if (key == "value") {
        vm.push(userdata.value);
        return true;
      }
      return false;
    });
    vm.setTable();
    vm.setMetaTable();
    vm.setGlobal("test_value");

    final slangScript = '''
    //slang
    assert(test_value.value == 123);
    ''';

    vm.load(slangScript);
    vm.call(0);
    vm.run();
    vm.pop();
  });
}
