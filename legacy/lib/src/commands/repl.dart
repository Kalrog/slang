import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:slang/src/commands/shared.dart';
import 'package:slang/src/repl.dart';

class ReplCommand extends Command {
  @override
  final description = "Runs a Slang repl";
  @override
  final name = "repl";

  ReplCommand() {}
  @override
  void run() {
    final vm = cliSlangVm();

    final repl = SlangRepl(vm);
    final arguments = argResults?.command?.rest ?? argResults?.rest;
    if (arguments != null && arguments.isNotEmpty) {
      final path = arguments[0];
      final file = File(path);

      final source = file.readAsStringSync();
      vm.load(source);
      vm.call(0);
    }
    repl.run();
  }
}
