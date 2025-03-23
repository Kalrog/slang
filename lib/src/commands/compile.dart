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
      vm.compile(source, origin: path);
      final bytes = vm.functionToBytes();

      /// new file name => remove .slang add .slb
      final newFile = File('${path.substring(0, path.length - 6)}.slb');
      newFile.writeAsBytesSync(bytes);
    }
  }
}
