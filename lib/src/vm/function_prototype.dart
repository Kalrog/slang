import 'dart:collection';

import 'package:slang/src/codegen/function_assembler.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class Upvalue {
  final String name;
  final int index;
  final bool isLocal;

  const Upvalue(this.name, this.index, this.isLocal);

  @override
  String toString() {
    return 'Upvalue{name: $name, index: $index, isLocal: $isLocal}';
  }
}

/// Prototype for a function.
/// The prototype contains a functions instructions and constants.
/// The prototype can be used to execute the function.
class FunctionPrototype {
  final UnmodifiableListView<int> instructions;
  final UnmodifiableListView<Object?> constants;
  final UnmodifiableListView<Upvalue> upvalues;
  final UnmodifiableListView<FunctionPrototype> children;
  final int maxStackSize;

  FunctionPrototype(
    List<int> instructions,
    List<Object?> constants,
    List<Upvalue> upvalues,
    List<FunctionPrototype> children, {
    required this.maxStackSize,
  })  : instructions = UnmodifiableListView(instructions),
        constants = UnmodifiableListView(constants),
        upvalues = UnmodifiableListView(upvalues),
        children = UnmodifiableListView(children);

  String instructionsToString({int? pc, int? context}) {
    StringBuffer buffer = StringBuffer();
    int start = context != null && pc != null ? pc - context : 0;
    int end =
        context != null && pc != null ? pc + context : instructions.length;

    if (start < 0) {
      start = 0;
    }
    if (end > instructions.length) {
      end = instructions.length;
    }
    for (var i = start; i < end; i++) {
      buffer.writeln(
          '${i == pc ? ">" : " "} $i: ${instructionToString(instructions[i])}');
    }
    return buffer.toString();
  }

  String constantsToString() {
    StringBuffer buffer = StringBuffer();
    for (var i = 0; i < constants.length; i++) {
      buffer.writeln('  $i: ${constants[i]}');
    }
    return buffer.toString();
  }

  String upvaluesToString() {
    StringBuffer buffer = StringBuffer();
    for (var i = 0; i < upvalues.length; i++) {
      buffer.writeln('  $i: ${upvalues[i]}');
    }
    return buffer.toString();
  }

  String childrenToString() {
    StringBuffer buffer = StringBuffer();
    for (var i = 0; i < children.length; i++) {
      buffer.writeln('  $i: {\n${children[i]}}');
    }
    return buffer.toString();
  }

  @override
  String toString({int? pc}) {
    // return 'Instructions:\n${instructionsToString(pc: pc)}\nConstants:\n${constantsToString()}\nUpvalues:\n${upvaluesToString()}\nChildren:\n${childrenToString()}';
    final sb = StringBuffer();

    sb.writeln('Instructions:');
    sb.writeln(instructionsToString());
    if (constants.isNotEmpty) {
      sb.writeln('Constants:');
      sb.writeln(constantsToString());
    }
    if (upvalues.isNotEmpty) {
      sb.writeln('Upvalues:');
      sb.writeln(upvaluesToString());
    }

    if (children.isNotEmpty) {
      sb.writeln('Children:');
      sb.writeln(childrenToString());
    }

    return sb.toString();
  }
}
