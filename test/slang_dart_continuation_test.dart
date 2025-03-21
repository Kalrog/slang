import 'package:slang/slang.dart';
import 'package:slang/src/commands/shared.dart';
import 'package:test/test.dart';

void main() {
  test("Dart Function Continuation", () {
    SlangVm vm = cliSlangVm();
    bool continuationRun = false;
    vm.registerDartFunction("runFuncAndReturnTrue", (vm) {
      vm.call(0, then: (vm) {
        vm.push(true);
        print("Continuation Run");
        continuationRun = true;
        return true;
      });
      return false;
    });

    final slangScript = '''
local thread = require("slang/thread");
local t = thread.create(func(){
  print("Thread Running");
  return runFuncAndReturnTrue(func(){
    thread.yield(123);
  });
});
 assert(thread.resume(t) == 123);
 assert(thread.resume(t));
''';

    vm.compile(slangScript);
    vm.call(0);
    assert(continuationRun);
  });
}
