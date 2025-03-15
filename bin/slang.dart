import 'dart:io';

import 'package:args/args.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/repl.dart';
import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/stdlib/std_lib.dart';

void main(List<String> arguments) {
  // print('Hello world: ${slang.calculate()}!');
  final vm = SlangVm();
  SlangStdLib.register(vm);
  SlangPackageLib.register(vm);

  ArgParser argParser = ArgParser();
  argParser.addFlag('debug', abbr: 'd', help: 'Debug mode', defaultsTo: false);
  argParser.addFlag('step', abbr: 's', help: 'Step mode', defaultsTo: false);

  argParser.addCommand('repl');

  argParser.addCommand('run');

  var result = argParser.parse(arguments);
  if (result['debug']) {
    vm.mode = ExecutionMode.runDebug;
  }
  if (result['step']) {
    vm.mode = ExecutionMode.step;
  }

  if (result.command?.name == 'repl') {
    //repl mode
    final repl = SlangRepl(vm);
    final arguments = result.command?.rest;
    if (arguments != null && arguments.isNotEmpty) {
      final path = arguments[0];
      final file = File(path);

      final source = file.readAsStringSync();
      vm.compile(source);
      vm.call(0);
    }
    repl.run();
  } else {
    final arguments = result.command?.rest ?? result.rest;
    if (arguments.isNotEmpty) {
      final path = arguments[0];
      final file = File(path);

      final source = file.readAsStringSync();
      vm.compile(source);
      vm.call(0);
    }
  }
}
