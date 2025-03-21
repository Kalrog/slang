import 'dart:io';

import 'package:slang/slang.dart';

class SlangRepl {
  SlangVm vm;

  SlangRepl(this.vm);

  void run() {
    print("Slang REPL");
    while (true) {
      stdout.write(">>> ");
      final line = stdin.readLineSync();
      if (line == null) {
        break;
      }
      if (line.isEmpty) {
        continue;
      }
      if (line == "exit") {
        break;
      }
      try {
        vm.compile(line, repl: true);
        vm.call(0);
        vm.run();
        print(vm.toAny(-1));
        vm.pop();
      } catch (e) {
        print(e);
      }
    }
  }
}
