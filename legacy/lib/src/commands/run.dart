import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/commands/shared.dart';

class RunCommand extends Command {
  @override
  final description = "Runs a Slang file";
  @override
  final name = "run";

  RunCommand() {
    argParser.addFlag('debug', abbr: 'd', help: 'Debug mode', defaultsTo: false);
    argParser.addFlag('step', abbr: 's', help: 'Step mode', defaultsTo: false);
  }
  @override
  void run() {
    final vm = cliSlangVm();
    if (argResults?['debug'] == true) {
      vm.debug.mode = DebugMode.runDebug;
    }
    if (argResults?['step'] == true) {
      vm.debug.mode = DebugMode.step;
    }
    final arguments = argResults?.command?.rest ?? argResults?.rest;
    if (arguments != null && arguments.isNotEmpty) {
      final path = arguments[0];
      final file = File(path);

      final args = arguments.sublist(1);
      vm.args = args;

      final source = file.readAsBytesSync();
      vm.load(source, origin: path);
      vm.call(0);
      vm.run();
      vm.pop();
    }
  }
}
