import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:slang/src/commands/shared.dart';

class CompileCommand extends Command {
  @override
  final description = "Compiles a Slang file";
  @override
  final name = "compile";

  CompileCommand() {}

  @override
  void run() {
    final vm = cliSlangVm();

    final arguments = argResults?.command?.rest ?? argResults?.rest;
    if (arguments != null && arguments.isNotEmpty) {
      final path = arguments[0];
      final file = File(path);

      final source = file.readAsStringSync();
      vm.load(source, origin: path);
      final bytes = vm.functionToBytes(minimal: true);

      /// new file name => remove .slang add .slb

      final newFile = File('${path.substring(0, path.lastIndexOf('.'))}.slb');
      newFile.writeAsBytesSync(bytes);
    }
  }
}
