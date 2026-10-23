import 'dart:io';

import 'package:dart_console/dart_console.dart';
import 'package:slang/slang.dart';

class SlangRepl {
  SlangVm vm;
  Console console = Console.scrolling();

  SlangRepl(this.vm);

  void run() {
    console.writeLine("Slang REPL");
    while (true) {
      console.write(">>> ");
      final line = console.readLine(cancelOnBreak: true);
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
        vm.load(line, repl: true);
        vm.call(0);
        vm.run();
        console.writeLine(vm.toAny(-1));
        vm.pop();
      } catch (e) {
        console.writeLine(e);
      }
    }
  }
}
