import 'dart:collection';

import 'package:slang/src/compiler/codegen/function_assembler.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

class Upvalue {
  final String name;
  final int index;
  final bool isLocal;

  const Upvalue(this.name, this.index, this.isLocal);

  Upvalue.fromJson(Map<String, dynamic> json)
      : name = json['name'],
        index = json['index'],
        isLocal = json['isLocal'];

  @override
  String toString() {
    return 'Upvalue{name: $name, index: $index, isLocal: $isLocal}';
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'index': index,
      'isLocal': isLocal,
    };
  }
}

/// Prototype for a function.
/// The prototype contains a functions instructions and constants.
/// The prototype can be used to execute the function.
class FunctionPrototype {
  final UnmodifiableListView<int> instructions;
  final UnmodifiableListView<SourceLocationInfo> sourceLocations;
  final UnmodifiableListView<Object?> constants;
  final UnmodifiableListView<Upvalue> upvalues;
  final UnmodifiableListView<FunctionPrototype> children;
  final int maxStackSize;
  final int nargs;
  final bool isVarArg;

  FunctionPrototype(
    List<int> instructions,
    List<SourceLocationInfo> sourceLocations,
    List<Object?> constants,
    List<Upvalue> upvalues,
    List<FunctionPrototype> children, {
    required this.maxStackSize,
    required this.isVarArg,
    required this.nargs,
  })  : instructions = UnmodifiableListView(instructions),
        sourceLocations = UnmodifiableListView(sourceLocations),
        constants = UnmodifiableListView(constants),
        upvalues = UnmodifiableListView(upvalues),
        children = UnmodifiableListView(children);

  FunctionPrototype.fromJson(Map<String, dynamic> json)
      : instructions = UnmodifiableListView(json['instructions']),
        sourceLocations = UnmodifiableListView(
            (json['sourceLocations'] as List).map((e) => SourceLocationInfo.fromJson(e))),
        constants = UnmodifiableListView(json['constants']),
        upvalues = UnmodifiableListView((json['upvalues'] as List).map((e) => Upvalue.fromJson(e))),
        children = UnmodifiableListView(
            (json['children'] as List).map((e) => FunctionPrototype.fromJson(e))),
        maxStackSize = json['maxStackSize'],
        isVarArg = json['isVarArg'],
        nargs = json['nargs'];

  Map<String, dynamic> toJson() {
    return {
      'instructions': instructions,
      'sourceLocations': sourceLocations.map((e) => e.toJson()).toList(),
      'constants': constants,
      'upvalues': upvalues.map((e) => e.toJson()).toList(),
      'children': children.map((e) => e.toJson()).toList(),
      'maxStackSize': maxStackSize,
      'isVarArg': isVarArg,
      'nargs': nargs,
    };
  }

  String instructionsToString({int? pc, int? context}) {
    StringBuffer buffer = StringBuffer();
    int start = context != null && pc != null ? pc - context : 0;
    int end = context != null && pc != null ? pc + context : instructions.length;

    if (start < 0) {
      start = 0;
    }
    if (end > instructions.length) {
      end = instructions.length;
    }
    for (var i = start; i < end; i++) {
      buffer.writeln(
          '${i == pc ? ">" : " "} $i: ${instructionToString(instructions[i])}  ${sourceLocations.where((sl) => sl.firstInstruction == i).map((sl) => sl.location.toString()).firstOrNull ?? ""}');
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
