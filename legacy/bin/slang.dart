import 'package:args/command_runner.dart';
import 'package:slang/src/commands/compile.dart';
import 'package:slang/src/commands/repl.dart';
import 'package:slang/src/commands/run.dart';
import 'package:slang/src/commands/test.dart';

void main(List<String> arguments) {
  final runner = CommandRunner("slang", "Interpreter for the Slang language")
    ..addCommand(ReplCommand())
    ..addCommand(RunCommand())
    ..addCommand(TestCommand())
    ..addCommand(CompileCommand());
  runner.run(arguments);
}
