import 'dart:collection';

import 'package:slang/src/compiler/codegen/function_assembler.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

/// Information about upvalues referenced by a function
/// Upvalues can either reference a local variable in the parent function or an upvalue in the parent function.
/// If the upvalue references a parent function upvalue, they form a linked list of upvalues that
/// must at some point, reference a local variable in some (great) parent function.
/// There is one exception to this rule, the Slang VM itself will load an Upvalue called
/// `_ENV` into the upvalue list of every function. This upvalue is used to reference the global environment.
class Upvalue {
  /// The name of the variable that the upvalue references.
  final String name;

  /// The index of the upvalue in either:
  /// - the parents stack frame if [isLocal] is true
  /// - the parent functions upvalue list if [isLocal] is false
  final int index;

  /// True if the upvalue is a local variable in the parent function.
  /// False if the upvalue is an upvalue in the parent function.
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
/// The prototype contains a functions instructions, constants, information on upvalues to capture,
/// and child functions.
class FunctionPrototype {
  /// The bytecode instructions for the function.
  final UnmodifiableListView<int> instructions;

  /// The source locations for different instructions.
  final UnmodifiableListView<SourceLocationInfo> sourceLocations;

  /// The constants used in the function.
  final UnmodifiableListView<Object?> constants;

  /// The upvalues that the function captures.
  final UnmodifiableListView<Upvalue> upvalues;

  /// Prototypes for the child functions(functions declared inside this function) of this function.
  final UnmodifiableListView<FunctionPrototype> children;

  /// The maximum stack size needed for variables in this function.
  final int maxVarStackSize;

  /// The number of arguments the function takes.
  final int nargs;

  /// True if the function takes a variable number of arguments.
  final bool isVarArg;

  /// Creates a new function prototype.
  FunctionPrototype(
    List<int> instructions,
    List<SourceLocationInfo> sourceLocations,
    List<Object?> constants,
    List<Upvalue> upvalues,
    List<FunctionPrototype> children, {
    required this.maxVarStackSize,
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
        maxVarStackSize = json['maxStackSize'],
        isVarArg = json['isVarArg'],
        nargs = json['nargs'];

  Map<String, dynamic> toJson() {
    return {
      'instructions': instructions,
      'sourceLocations': sourceLocations.map((e) => e.toJson()).toList(),
      'constants': constants,
      'upvalues': upvalues.map((e) => e.toJson()).toList(),
      'children': children.map((e) => e.toJson()).toList(),
      'maxStackSize': maxVarStackSize,
      'isVarArg': isVarArg,
      'nargs': nargs,
    };
  }

  /// Returns a string representation of the instructions in the function.
  /// If [pc] is provided, the program counter will be highlighted.
  /// if [context] is provided, that number of instructions before and after the pc will be shown.
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

  /// Returns a string representation of the constants in the function.
  String constantsToString() {
    StringBuffer buffer = StringBuffer();
    for (var i = 0; i < constants.length; i++) {
      buffer.writeln('  $i: ${constants[i]}');
    }
    return buffer.toString();
  }

  /// Returns a string representation of the upvalues in the function.
  String upvaluesToString() {
    StringBuffer buffer = StringBuffer();
    for (var i = 0; i < upvalues.length; i++) {
      buffer.writeln('  $i: ${upvalues[i]}');
    }
    return buffer.toString();
  }

  /// Returns a string representation of the child functions of this function.
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
