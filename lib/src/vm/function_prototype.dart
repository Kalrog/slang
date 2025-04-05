import 'dart:collection';
import 'dart:typed_data';

import 'package:slang/src/bytes.dart';
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

  @override
  bool operator ==(Object other) {
    if (other is Upvalue) {
      return name == other.name && index == other.index && isLocal == other.isLocal;
    }
    return false;
  }

  @override
  int get hashCode {
    return Object.hash(name, index, isLocal);
  }
}

/// Prototype for a function.
/// The prototype contains a functions instructions, constants, information on upvalues to capture,
/// and child functions.
class FunctionPrototype {
  /// The bytecode instructions for the function.
  final Uint32List instructions;

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
  })  : instructions = Uint32List.fromList(instructions),
        sourceLocations = UnmodifiableListView(sourceLocations),
        constants = UnmodifiableListView(constants),
        upvalues = UnmodifiableListView(upvalues),
        children = UnmodifiableListView(children);

  FunctionPrototype.fromJson(Map<String, dynamic> json)
      : instructions = Uint32List.fromList(json['instructions']),
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

  @override
  bool operator ==(Object other) {
    if (other is FunctionPrototype) {
      return instructions == other.instructions &&
          sourceLocations == other.sourceLocations &&
          constants == other.constants &&
          upvalues == other.upvalues &&
          children == other.children &&
          maxVarStackSize == other.maxVarStackSize &&
          isVarArg == other.isVarArg &&
          nargs == other.nargs;
    }
    return false;
  }

  @override
  int get hashCode {
    return Object.hash(instructions, sourceLocations, constants, upvalues, children,
        maxVarStackSize, isVarArg, nargs);
  }
}

enum TypeMarker {
  integer,
  double,
  string,
  boolean,
  nullType;
}

class PrototypeEncoder {
  static const slangHeader = [83, 76, 65, 78, 71];
  PrototypeEncoder();
  Uint8List encode(FunctionPrototype p) {
    ByteWriter wr = ByteWriter();
    wr.writeAll(Uint8List.fromList(slangHeader));
    _encodeProto(p, wr);
    return wr.toBytes();
  }

  void _encodeProto(FunctionPrototype p, ByteWriter wr) {
    wr.writeInt(p.maxVarStackSize);
    wr.writeInt(p.nargs);
    wr.writeBool(p.isVarArg);

    wr.writeInt(p.instructions.length);
    for (var i in p.instructions) {
      wr.writeInt(i);
    }

    wr.writeInt(p.sourceLocations.length);
    for (var sl in p.sourceLocations) {
      _encodeSourceLocationInfo(sl, wr);
    }

    wr.writeInt(p.constants.length);
    for (var c in p.constants) {
      _encodeConstant(c, wr);
    }

    wr.writeInt(p.upvalues.length);
    for (var u in p.upvalues) {
      _encodeUpvalue(u, wr);
    }

    wr.writeInt(p.children.length);
    for (var c in p.children) {
      _encodeProto(c, wr);
    }
  }

  void _encodeSourceLocationInfo(SourceLocationInfo i, ByteWriter wr) {
    wr.writeInt(i.firstInstruction);
    _encodeSourceLocation(i.location, wr);
  }

  void _encodeSourceLocation(SourceLocation sl, ByteWriter wr) {
    wr.writeString(sl.origin);
    wr.writeInt(sl.line);
    wr.writeInt(sl.column);
  }

  void _encodeConstant(Object? c, ByteWriter wr) {
    switch (c) {
      case String s:
        wr.writeByte(TypeMarker.string.index);
        wr.writeString(s);
      case int i:
        wr.writeByte(TypeMarker.integer.index);
        wr.writeInt(i);
      case double d:
        wr.writeByte(TypeMarker.double.index);
        wr.writeDouble(d);
      case bool b:
        wr.writeByte(TypeMarker.boolean.index);
        wr.writeBool(b);
      case null:
        wr.writeByte(TypeMarker.nullType.index);
      default:
        throw ArgumentError('Unsupported constant type: ${c.runtimeType}');
    }
  }

  void _encodeUpvalue(Upvalue u, ByteWriter wr) {
    wr.writeString(u.name);
    wr.writeInt(u.index);
    wr.writeBool(u.isLocal);
  }

  FunctionPrototype? decode(Uint8List bytes) {
    ByteReader rd = ByteReader(bytes);
    List<int> header = List.generate(slangHeader.length, (index) => rd.readByte());
    for (var i = 0; i < slangHeader.length; i++) {
      if (header[i] != slangHeader[i]) {
        return null;
      }
    }

    return _decodeProto(rd);
  }

  FunctionPrototype _decodeProto(ByteReader rd) {
    int maxVarStackSize = rd.readInt();
    int nargs = rd.readInt();
    bool isVarArg = rd.readBool();
    int nInstructions = rd.readInt();
    List<int> instructions = List.generate(nInstructions, (index) => rd.readInt());
    int nSourceLocations = rd.readInt();
    List<SourceLocationInfo> sourceLocations =
        List.generate(nSourceLocations, (index) => _decodeSourceLocationInfo(rd));
    int nConstants = rd.readInt();
    List<Object?> constants = List.generate(nConstants, (index) => _decodeConstant(rd));
    int nUpvalues = rd.readInt();
    List<Upvalue> upvalues = List.generate(nUpvalues, (index) => _decodeUpvalue(rd));
    int nChildren = rd.readInt();
    List<FunctionPrototype> children = List.generate(nChildren, (index) => _decodeProto(rd));
    return FunctionPrototype(instructions, sourceLocations, constants, upvalues, children,
        maxVarStackSize: maxVarStackSize, nargs: nargs, isVarArg: isVarArg);
  }

  SourceLocationInfo _decodeSourceLocationInfo(ByteReader rd) {
    int firstInstruction = rd.readInt();
    SourceLocation location = _decodeSourceLocation(rd);
    return SourceLocationInfo(firstInstruction, location);
  }

  SourceLocation _decodeSourceLocation(ByteReader rd) {
    String origin = rd.readString();
    int line = rd.readInt();
    int column = rd.readInt();
    return SourceLocation(origin, line, column);
  }

  Object? _decodeConstant(ByteReader rd) {
    TypeMarker marker = TypeMarker.values[rd.readByte()];
    switch (marker) {
      case TypeMarker.string:
        return rd.readString();
      case TypeMarker.integer:
        return rd.readInt();
      case TypeMarker.double:
        return rd.readDouble();
      case TypeMarker.boolean:
        return rd.readBool();
      case TypeMarker.nullType:
        return null;
    }
  }

  Upvalue _decodeUpvalue(ByteReader rd) {
    String name = rd.readString();
    int index = rd.readInt();
    bool isLocal = rd.readBool();
    return Upvalue(name, index, isLocal);
  }
}
