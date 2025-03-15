import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/commands/shared.dart';

class TestCommand extends Command {
  @override
  final description = "Runs tests";
  @override
  final name = "test";

  TestCommand();

  @override
  void run() {
    final vm = cliSlangVm();
    final arguments = argResults?.command?.rest;
    final path = arguments?[0] ?? "./test";
    //search for files ending in test.slang in the path
    final testFiles = <File>[];
    final dir = Directory(path);
    final files = dir.listSync();
    for (final file in files) {
      if (file is File && file.path.endsWith("test.slang")) {
        testFiles.add(file);
      }
    }

    for (final testFile in testFiles) {
      compileTestFile(vm, testFile);
    }

    vm.compile("""
      local test = require("slang/test")
      test.run()
    """, origin: "test runner");
    vm.call(0);
  }

  void compileTestFile(SlangVm vm, File file) {
    final content = file.readAsStringSync();
    vm.compile(content, origin: file.path);
    vm.call(0);
  }
}
