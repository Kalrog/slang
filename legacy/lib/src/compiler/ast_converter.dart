import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/userdata.dart';

abstract class AstEncoder<T> extends AstNodeVisitor<T, Null> {
  T encodeNode(AstNode node, Map<String, T?> values);
  T encodePrimitive(AstNode node, dynamic value);
  T encodeList(AstNode node, List<T> values);

  @override
  T visit(AstNode node, [Null arg]) => node.accept(this, null);

  T? maybeVisit(AstNode? node) => node == null ? null : visit(node);

  @override
  T visitAssignment(Assignment node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Assignment'),
        'left': visit(node.left),
        'right': visit(node.right),
      });

  @override
  T visitBinOp(BinOp node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'BinOp'),
        'left': visit(node.left),
        'op': encodePrimitive(node, node.op),
        'right': visit(node.right),
      });

  @override
  T visitBlock(Block node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Block'),
        'statements': encodeList(
            node,
            <Statement>[
              ...node.statements,
              if (node.finalStatement != null) node.finalStatement!,
            ].map(visit).toList()),
      });

  @override
  T visitBreak(Break node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Break'),
      });

  @override
  T visitConstPattern(ConstPattern node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'ConstPattern'),
        'value': visit(node.value),
      });

  @override
  T visitDeclaration(Declaration node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Declaration'),
        'is_local': encodePrimitive(node, node.isLocal),
        'left': visit(node.left),
        'right': maybeVisit(node.right),
      });

  @override
  T visitDoubleLiteral(DoubleLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Double'),
        'value': encodePrimitive(node, node.value),
      });

  @override
  T visitFalseLiteral(FalseLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'False'),
      });

  @override
  T visitField(Field node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Field'),
        'key': maybeVisit(node.key),
        'value': visit(node.value),
      });

  @override
  T visitFieldPattern(FieldPattern node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'FieldPattern'),
        'key': maybeVisit(node.key),
        'value': visit(node.value),
      });

  @override
  T visitForInLoop(ForInLoop node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'ForIn'),
        'pattern': visit(node.pattern),
        'itterator': visit(node.itterator),
        'body': visit(node.body),
      });

  @override
  T visitForLoop(ForLoop node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'For'),
        'init': maybeVisit(node.init),
        'condition': visit(node.condition),
        'update': maybeVisit(node.update),
        'body': visit(node.body),
      });

  @override
  T visitFunctionCall(FunctionCall node, [Null arg]) => node.name != null
      ? encodeNode(node, {
          'type': encodePrimitive(node, 'Invoke'),
          'receiver': visit(node.function),
          'name': visit(node.name!),
          'args': encodeList(node, node.args.map(visit).toList()),
        })
      : encodeNode(node, {
          'type': encodePrimitive(node, 'Call'),
          'function': visit(node.function),
          'args': encodeList(node, node.args.map(visit).toList()),
        });

  @override
  T visitFunctionExpression(FunctionExpression node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Function'),
        'params': encodeList(node, node.params.map(visit).toList()),
        'body': visit(node.body),
      });

  @override
  T visitFunctionStatement(FunctionCallStatement node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'CallStat'),
        'call': visit(node.call),
      });

  @override
  T visitIfStatement(IfStatement node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'If'),
        'condition': visit(node.condition),
        'thenBranch': visit(node.thenBranch),
        'elseBranch': maybeVisit(node.elseBranch),
      });

  @override
  T visitIndex(Index node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Index'),
        'receiver': visit(node.receiver),
        'index': visit(node.index),
        'dotStyle': encodePrimitive(node, node.dotStyle),
      });

  @override
  T visitIntLiteral(IntLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Int'),
        'value': encodePrimitive(node, node.value),
      });

  @override
  T visitIdentifier(Identifier node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Identifier'),
        'value': encodePrimitive(node, node.value),
      });

  @override
  T visitNullLiteral(NullLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Null'),
      });

  @override
  T visitLetExp(LetExp node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Let'),
        'pattern': visit(node.pattern),
        'right': visit(node.right),
      });

  @override
  T visitReturnStatement(ReturnStatement node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Return'),
        'value': visit(node.value),
      });

  @override
  T visitStringLiteral(StringLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'String'),
        'value': encodePrimitive(node, node.value),
      });

  @override
  T visitTableLiteral(TableLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Table'),
        'fields': encodeList(node, node.fields.map(visit).toList()),
      });

  @override
  T visitTablePattern(TablePattern node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'TablePattern'),
        'type_check': encodePrimitive(node, node.type),
        'fields': encodeList(node, node.fields.map(visit).toList()),
      });
  @override
  T visitTrueLiteral(TrueLiteral node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'True'),
      });

  @override
  T visitUnOp(UnOp node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'UnOp'),
        'op': encodePrimitive(node, node.op),
        'operand': visit(node.operand),
      });

  @override
  T visitVarPattern(VarPattern node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'VarPattern'),
        'isLocal': encodePrimitive(node, node.isLocal),
        'canBeNull': encodePrimitive(node, node.canBeNull),
        'name': visit(node.name),
      });

  @override
  T visitQuote(Quote node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Quote'),
        'ast_type': encodePrimitive(node, node.type),
        'ast': visit(node.ast),
      });

  @override
  T visitUnquote(Unquote node, [Null arg]) => encodeNode(node, {
        'type': encodePrimitive(node, 'Unquote'),
        'ast_type': encodePrimitive(node, node.type),
        'ast': visit(node.ast),
      });
}

class AstToTableLiteral extends AstEncoder<Exp> {
  TableLiteral tableLiteralFromMap(Token? token, Map<String, Exp?> map) {
    final table = TableLiteral(
        token,
        map.entries
            .where((e) => e.value != null)
            .map((e) => Field(token, StringLiteral(token, e.key), e.value!))
            .toList());
    if (map['type'] != null) {
      table.fields.add(Field(
          token,
          StringLiteral(token, "meta"),
          TableLiteral(token, [
            Field(token, StringLiteral(token, "__type"), map['type']!),
          ])));
    }
    return table;
  }

  TableLiteral tableLiteralFromList(Token? token, List<Exp> list) {
    return TableLiteral(token, list.map((e) => Field(token, null, e)).toList());
  }

  @override
  Exp encodeList(AstNode node, List<Exp> values) {
    return tableLiteralFromList(node.token, values);
  }

  @override
  Exp encodeNode(AstNode node, Map<String, Exp?> values) {
    return tableLiteralFromMap(node.token, values);
  }

  @override
  Exp visit(AstNode node, [Null arg]) {
    if (node is Unquote) {
      return node.ast as Exp;
    }
    return super.visit(node, arg);
  }

  @override
  Exp encodePrimitive(AstNode node, dynamic value) {
    return switch (value) {
      String s => StringLiteral(node.token, s),
      int i => IntLiteral(node.token, i),
      double d => DoubleLiteral(node.token, d),
      bool b => b ? TrueLiteral(node.token) : FalseLiteral(node.token),
      null => NullLiteral(node.token),
      _ => throw ArgumentError('Invalid value: $value'),
    };
  }
}

SlangTable astToTable(AstNode node) {
  return AstToSlangTable().visit(node);
}

class AstToSlangTable extends AstEncoder<dynamic> {
  @override
  SlangTable encodeList(AstNode node, List values) {
    return SlangTable.fromList(values);
  }

  @override
  SlangTable encodeNode(AstNode node, Map<String, dynamic> values) {
    final table = SlangTable.fromMap(values);
    if (values['type'] != null) {
      table.metatable = SlangTable.fromMap({
        '__type': values['type'],
      });
    }
    return table;
  }

  @override
  dynamic encodePrimitive(AstNode node, value) {
    return value;
  }
}

T decodeAst<T extends AstNode?>(dynamic table) {
  try {
    if (table == null && null is T) {
      return null as T;
    }

    final Userdata? tokenUserdata = table['token'];
    final Token? token = tokenUserdata?.value as Token?;
    final ast = table['ast'];
    if (ast == null) {
      return SlangTableAstDecoder(token).decode<T>(table);
    }
    return SlangTableAstDecoder(token).decode<T>(table['ast']);
  } catch (e) {
    print("Failed to decode $table as AST:\n $e");
    rethrow;
  }
}

class SlangTableAstDecoder {
  /// The token to use for the decoded AST nodes.
  /// Should be the token of the unqoute node that returned the ast.
  final Token? token;

  SlangTableAstDecoder(this.token);

  /// Decodes a SlangTable into an AST node of type T.
  ///
  /// [table] The SlangTable to decode
  /// Returns an AST node of type T
  T decode<T extends AstNode?>(dynamic table) {
    if (table == null && null is T) {
      return null as T;
    }
    if (table is! SlangTable) {
      throw ArgumentError('Invalid table: $table of type ${table.runtimeType} expected $T');
    }

    switch (table['type']) {
      case "Assignment":
        return Assignment(token, decode<Exp>(table['left']), decode<Exp>(table['right'])) as T;
      case "BinOp":
        return BinOp(token, decode<Exp>(table['left']), table['op'] as String,
            decode<Exp>(table['right'])) as T;
      case "Block":
        final statements = decodeList<Statement>(table['statements']);
        if (statements.lastOrNull case ReturnStatement() || Break()) {
          return Block(
            token,
            statements.sublist(0, statements.length - 1),
            statements.last,
          ) as T;
        } else {
          return Block(token, statements) as T;
        }
      case "Break":
        return Break(token) as T;
      case "ConstPattern":
        return ConstPattern(token, decode<Exp>(table['value'])) as T;
      case "Declaration":
        return Declaration(token, table['is_local'] as bool, decode<Exp>(table['left']),
            maybeDecode<Exp>(table['right'])) as T;
      case "Double":
        return DoubleLiteral(token, table['value'] as double) as T;
      case "False":
        return FalseLiteral(token) as T;
      case "Field":
        return Field(
          token,
          maybeDecode<Exp>(table['key']),
          decode<Exp>(table['value']),
        ) as T;
      case "FieldPattern":
        return FieldPattern(
          token,
          maybeDecode<Exp>(table['key']),
          decode<Pattern>(table['value']),
        ) as T;
      case "ForIn":
        return ForInLoop(
          token,
          decode<Pattern>(table['pattern']),
          decode<Exp>(table['itterator']),
          decode<Statement>(table['body']),
        ) as T;
      case "For":
        return ForLoop(
          token,
          maybeDecode<Statement>(table['init']),
          decode<Exp>(table['condition']),
          maybeDecode<Statement>(table['update']),
          decode<Statement>(table['body']),
        ) as T;
      case "Invoke":
        return FunctionCall(
          token,
          decode<Exp>(table['receiver']),
          decode<Identifier>(table['name']),
          decodeList<Exp>(table['args']),
        ) as T;
      case "Call":
        return FunctionCall(
          token,
          decode<Exp>(table['function']),
          null,
          decodeList<Exp>(table['args']),
        ) as T;
      case "Function":
        return FunctionExpression(
          token,
          decodeList<Identifier>(table['params']),
          decode<Block>(table['body']),
        ) as T;
      case "CallStat":
        return FunctionCallStatement(
          token,
          decode<FunctionCall>(table['call']),
        ) as T;
      case "If":
        return IfStatement(
          token,
          decode<Exp>(table['condition']),
          decode<Statement>(table['thenBranch']),
          maybeDecode<Statement>(table['elseBranch']),
        ) as T;
      case "Index":
        return Index(
          token,
          decode<Exp>(table['receiver']),
          decode<Exp>(table['index']),
          dotStyle: table['dotStyle'] as bool? ?? false,
        ) as T;
      case "Int":
        return IntLiteral(token, table['value'] as int) as T;
      case "Identifier":
        return Identifier(token, table['value'] as String) as T;
      case "Null":
        return NullLiteral(token) as T;
      case "Let":
        return LetExp(
          token,
          decode<Pattern>(table['pattern']),
          decode<Exp>(table['right']),
        ) as T;
      case "Return":
        return ReturnStatement(
          token,
          decode<Exp>(table['value']),
        ) as T;
      case "String":
        return StringLiteral(token, table['value'] as String) as T;
      case "Table":
        return TableLiteral(
          token,
          decodeList<Field>(table['fields']),
        ) as T;
      case "TablePattern":
        return TablePattern(
          token,
          decodeList<FieldPattern>(table['fields']),
          type: table['type_check'] as String?,
        ) as T;
      case "True":
        return TrueLiteral(token) as T;
      case "UnOp":
        return UnOp(
          token,
          table['op'] as String,
          decode<Exp>(table['operand']),
        ) as T;
      case "VarPattern":
        return VarPattern(
          token,
          decode<Identifier>(table['name']),
          isLocal: table['isLocal'] as bool,
          canBeNull: table['canBeNull'] as bool,
        ) as T;
      case "Quote":
        return Quote(token, table['ast_type'] as String, decode<AstNode>(table['ast'])) as T;
      case "Unquote":
        return Unquote(token, table['ast_type'] as String, decode<AstNode>(table['ast'])) as T;

      default:
        throw ArgumentError('Invalid type: ${table['type']} value: $table');
    }
  }

  T? maybeDecode<T extends AstNode>(dynamic table) {
    if (table == null) {
      return null;
    }
    return decode<T>(table);
  }

  List<T> decodeList<T extends AstNode>(dynamic table) {
    if (table is! SlangTable) {
      throw ArgumentError('Invalid table: $table');
    }
    return table.values.map((e) => decode<T>(e)).toList();
  }
}
