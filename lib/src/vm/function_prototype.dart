import 'dart:collection';

import 'package:slang/src/vm/slang_vm_bytecode.dart';

/// Prototype for a function.
/// The prototype contains a functions instructions and constants.
/// The prototype can be used to execute the function.
class FunctionPrototype {
  final UnmodifiableListView<int> instructions;
  final UnmodifiableListView<Object?> constants;
  final int maxStackSize;

  FunctionPrototype(
    List<int> instructions,
    List<Object?> constants, {
    required this.maxStackSize,
  })  : instructions = UnmodifiableListView(instructions),
        constants = UnmodifiableListView(constants);

  @override
  String toString({int? pc = -1}) {
    StringBuffer buffer = StringBuffer();
    buffer.writeln('Instructions:');
    for (var i = 0; i < instructions.length; i++) {
      buffer.writeln(
          '${i == pc ? ">" : " "} $i: ${instructionToString(instructions[i])}');
    }
    buffer.writeln('Constants:');
    for (var i = 0; i < constants.length; i++) {
      buffer.writeln('  $i: ${constants[i]}');
    }
    return buffer.toString();
  }
}
