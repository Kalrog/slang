import 'package:petitparser/petitparser.dart';
import 'package:slang/src/slang_vm.dart';

void main() {
  int someFunc(String a, List<int> b) {
    return 1;
  }

  T genericFunc<T, S>(T a, S b) {
    return a;
  }

  void voidFunc() {}

  int metaFunc(int Function(String) a, String b) {
    return a(b);
  }

  T genericMetaFunc<T, S>(T Function(S) a, S b) {
    return a(b);
  }

  final parser = DartFuncTypeParser().build();
  var result = parser.parse(someFunc.runtimeType.toString());
  print(someFunc.runtimeType);
  print(result);
  result = parser.parse(genericFunc.runtimeType.toString());
  print(genericFunc.runtimeType);
  print(result);
  result = parser.parse(genericFunc<int, int>.runtimeType.toString());
  print(genericFunc<int, int>.runtimeType);
  print(result);
  result = parser.parse(voidFunc.runtimeType.toString());
  print(voidFunc.runtimeType);
  print(result);
  result = parser.parse(metaFunc.runtimeType.toString());
  print(metaFunc.runtimeType);
  print(result);
  result = parser.parse(genericMetaFunc.runtimeType.toString());
  print(genericMetaFunc.runtimeType);
  print(result);
}

// (String, List<int>) => int
// <Y0, Y1>(Y0, Y1) => Y0
// (int, int) => int
// () => void

class DartFuncTypeGrammar extends GrammarDefinition {
  Parser<Token> token(Object source, [String? message]) {
    if (source is String) {
      return source
          .toParser(message: "Expected: ${message ?? source}")
          .token()
          .trim();
    } else if (source is Parser) {
      ArgumentError.checkNotNull(message, 'message');
      return source.flatten(message).token().trim();
    } else {
      throw ArgumentError('Invalid argument: $source');
    }
  }

  @override
  Parser start() => ref0(funcType).end();

  Parser funcType() =>
      ref0(generic).optional() &
      ref0(paramList) &
      ref1(token, '=>') &
      ref0(type);

  Parser generic() =>
      ref1(token, '<') &
      ref0(identifier)
          .starSeparated(ref1(token, ','))
          .map((list) => list.elements) &
      ref1(token, '>');

  Parser paramList() =>
      ref1(token, '(') &
      ref0(param).starSeparated(ref1(token, ',')).map((list) => list.elements) &
      ref1(token, ')');

  Parser param() => ref0(type);

  Parser type() =>
      (ref0(identifier) & ref0(generic).optional()) | ref0(funcType);

  /// Any letter or underscore followed by any letter, number, or underscore.
  Parser identifier() => ref2(
      token, pattern('a-zA-Z_') & pattern('a-zA-Z0-9_').star(), 'identifier');
}

abstract class DartFuncTypeVisitor<R> {
  R visitGenericDecl(GenericDeclNode node);
  R visitGenericRef(GenericRefNode node);
  R visitBasicType(BasicTypeNode node);
  R visitGenericType(GenericTypeNode node);
  R visitDartFuncType(DartFuncType node);
}

class ToStringVisitor implements DartFuncTypeVisitor<void> {
  StringBuffer sb = StringBuffer();
  String visit(DartFuncTypeNode node) {
    node.accept(this);
    return sb.toString();
  }

  @override
  void visitBasicType(BasicTypeNode node) {
    sb.write(node.name);
  }

  @override
  void visitDartFuncType(DartFuncType node) {
    if (node.generic != null) {
      sb.write('<');
      for (var i = 0; i < node.generic!.length; i++) {
        node.generic![i].accept(this);
        if (i < node.generic!.length - 1) {
          sb.write(', ');
        }
      }
      sb.write('>');
    }
    sb.write('(');
    for (var i = 0; i < node.param!.length; i++) {
      node.param![i].accept(this);
      if (i < node.param!.length - 1) {
        sb.write(', ');
      }
    }
    sb.write(') => ');
    node.returnType.accept(this);
  }

  @override
  void visitGenericDecl(GenericDeclNode node) {
    sb.write(node.name);
  }

  @override
  void visitGenericRef(GenericRefNode node) {
    sb.write(node.decl.name);
  }

  @override
  void visitGenericType(GenericTypeNode node) {
    node.basicType.accept(this);
    sb.write('<');
    for (var i = 0; i < node.genericTypes.length; i++) {
      node.genericTypes[i].accept(this);
      if (i < node.genericTypes.length - 1) {
        sb.write(', ');
      }
    }
    sb.write('>');
  }
}

class GenericDeclResolver implements DartFuncTypeVisitor<DartFuncTypeNode> {
  final Map<String, GenericDeclNode> genericMap = {};
  DartFuncTypeNode resolve(DartFuncTypeNode node) {
    return node.accept(this);
  }

  @override
  DartFuncTypeNode visitGenericDecl(GenericDeclNode node) {
    genericMap[node.name] = node;
    return node;
  }

  @override
  DartFuncTypeNode visitDartFuncType(DartFuncType node) {
    final generic = node.generic
        ?.map((node) => node.accept(this))
        .cast<GenericDeclNode>()
        .toList();
    final param =
        node.param?.map((type) => type.accept(this)).cast<TypeNode>().toList();
    final returnType = node.returnType.accept(this) as TypeNode;
    return DartFuncType(generic: generic, param: param, returnType: returnType);
  }

  @override
  DartFuncTypeNode visitBasicType(BasicTypeNode node) {
    final decl = genericMap[node.name];
    if (decl != null) {
      return GenericRefNode(decl);
    } else {
      return node;
    }
  }

  @override
  DartFuncTypeNode visitGenericRef(GenericRefNode node) {
    return node;
  }

  @override
  DartFuncTypeNode visitGenericType(GenericTypeNode node) {
    final basicType = node.basicType.accept(this) as BasicTypeNode;
    final genericTypes = node.genericTypes
        .map((type) => type.accept(this))
        .cast<TypeNode>()
        .toList();
    return GenericTypeNode(basicType, genericTypes);
  }
}

abstract class DartFuncTypeNode {
  R accept<R>(DartFuncTypeVisitor<R> visitor);
  @override
  String toString() {
    return ToStringVisitor().visit(this);
  }
}

class DartFuncType extends TypeNode {
  final List<GenericDeclNode>? generic;
  final List<TypeNode>? param;
  final TypeNode returnType;

  DartFuncType({this.generic, this.param, required this.returnType});

  @override
  R accept<R>(DartFuncTypeVisitor<R> visitor) {
    return visitor.visitDartFuncType(this);
  }
}

class GenericDeclNode extends DartFuncTypeNode {
  final String name;
  GenericDeclNode(this.name);

  @override
  R accept<R>(DartFuncTypeVisitor<R> visitor) {
    return visitor.visitGenericDecl(this);
  }
}

abstract class TypeNode extends DartFuncTypeNode {}

class GenericRefNode extends TypeNode {
  GenericDeclNode decl;

  GenericRefNode(this.decl);

  @override
  R accept<R>(DartFuncTypeVisitor<R> visitor) {
    return visitor.visitGenericRef(this);
  }
}

class BasicTypeNode extends TypeNode {
  final String name;
  BasicTypeNode(this.name);

  @override
  R accept<R>(DartFuncTypeVisitor<R> visitor) {
    return visitor.visitBasicType(this);
  }
}

class GenericTypeNode extends TypeNode {
  final BasicTypeNode basicType;
  final List<TypeNode> genericTypes;
  GenericTypeNode(this.basicType, this.genericTypes);

  @override
  R accept<R>(DartFuncTypeVisitor<R> visitor) {
    return visitor.visitGenericType(this);
  }
}

class DartFuncTypeParser extends DartFuncTypeGrammar {
  static DartFuncType parse(String source) {
    final parser = DartFuncTypeParser().build();
    final result = parser.parse(source);
    if (result is Success) {
      return result.value;
    } else {
      throw ArgumentError(result.message);
    }
  }

  @override
  Parser start() =>
      super.start().map((value) => GenericDeclResolver().resolve(value));

  @override
  Parser identifier() =>
      super.identifier().map((value) => BasicTypeNode(value.value));

  @override
  Parser generic() => super.generic().map((value) => value[1]);

  @override
  Parser type() => super.type().map((value) {
        if (value is DartFuncType) {
          return value;
        }
        if (value[1] != null) {
          List<TypeNode> generic = (value[1] ?? []).cast<TypeNode>();
          return GenericTypeNode(value[0], generic);
        }
        return value[0];
      });

  @override
  Parser funcType() => super.funcType().map((value) {
        final typeDecls = (value[0] ?? [])
            .map<GenericDeclNode>((decl) => GenericDeclNode(decl.name))
            .toList();
        return DartFuncType(
            generic: typeDecls.isEmpty ? null : typeDecls,
            param: value[1].cast<TypeNode>(),
            returnType: value[3]);
      });

  @override
  Parser paramList() => super.paramList().map((value) => value[1]);
}
