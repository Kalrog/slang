import 'package:meta/meta.dart';
import 'package:petitparser/debug.dart';
import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/codegen/optimizer.dart';
import 'package:slang/src/compiler/parser/slang_grammar.dart';

/// A parser that is not defined, but that can be set at a later
/// point in time.
class AlwaysSettableParser<R> extends DelegateParser<R, R> {
  AlwaysSettableParser(super.delegate);

  @override
  AlwaysSettableParser<R> copy() => AlwaysSettableParser<R>(delegate);

  @override
  int fastParseOn(String buffer, int position) => delegate.fastParseOn(buffer, position);

  @override
  Result<R> parseOn(Context context) => delegate.parseOn(context);

  /// Sets the receiver to delegate to [parser].
  void set(Parser<R> parser) {
    delegate = parser;
  }
}

class ExpressionGroupLevel {
  final String name;
  final ExpressionGroup Function(ExpressionBuilder builder) add;

  ExpressionGroupLevel(this.name, this.add);
}

class PrimitiveExpressionLevel {
  static const _trace = [];
  final String name;
  final Parser parser;

  PrimitiveExpressionLevel(this.name, Parser parser)
      : parser = _trace.contains(name) ? trace(parser) : parser;
}

class SlangParser extends SlangGrammar {
  ExpressionBuilder expressionBuilder = ExpressionBuilder();

  late final List<PrimitiveExpressionLevel> _primitiveExpressionLevels = [
    PrimitiveExpressionLevel("unquote", ref0(unquote)),
    PrimitiveExpressionLevel("quote", ref0(quote)),
    PrimitiveExpressionLevel("identifier", ref0(identifier)),
    PrimitiveExpressionLevel("doubleLiteral", ref0(doubleLiteral)),
    PrimitiveExpressionLevel("intLiteral", ref0(intLiteral)),
    PrimitiveExpressionLevel("stringLiteral", ref0(stringLiteral)),
    PrimitiveExpressionLevel("trueLiteral", ref0(trueLiteral)),
    PrimitiveExpressionLevel("falseLiteral", ref0(falseLiteral)),
    PrimitiveExpressionLevel("nullLiteral", ref0(nullLiteral)),
    PrimitiveExpressionLevel("patternAssignmentExp", ref0(patternAssignmentExp)),
    PrimitiveExpressionLevel("listLiteral", ref0(tableLiteral)),
    PrimitiveExpressionLevel("functionExpression", ref0(functionExpression)),
  ];
  late final List<ExpressionGroupLevel> _expressionGroupLevels = [
    ExpressionGroupLevel("bracket", (builder) {
      return builder.group()
        ..wrapper(ref1(token, '('), ref1(token, ')'), (left, value, right) => value);
    }),
    ExpressionGroupLevel("indexAndCall", (builder) {
      return builder.group()
        ..postfix(ref1(token, '.') & ref0(identifier), (left, op) {
          final name = op[1] as Identifier;
          return Index(op[0], left, StringLiteral(name.token, name.value), dotStyle: true);
        })
        ..postfix(ref1(token, '[') & expressionBuilder.loopback & ref1(token, ']'), (left, op) {
          final index = op[1] as Exp;
          return Index(op[0], left, index);
        })
        ..postfix(ref0(nameAndArgs), (left, op) {
          final name = op[0];
          final args = op[1] as List<dynamic>;
          final token = op[2];
          return FunctionCall(token, left, name, args.cast<Exp>());
        });
    }),
    ExpressionGroupLevel("power", (builder) {
      return builder.group()
        ..right(ref1(token, '^'), (left, op, right) {
          return BinOp(op, left, op.value, right);
        });
    }),
    ExpressionGroupLevel("unary", (builder) {
      return builder.group()
        ..prefix(ref1(token, '-').seq(char('{').not()).pick(0) | ref1(token, 'not'),
            (opToken, exp) => UnOp(opToken, opToken.value, exp));
    }),
    ExpressionGroupLevel("multiply", (builder) {
      return builder.group()
        ..left(ref1(token, '*') | ref1(token, '/') | ref1(token, '%'),
            (left, op, right) => BinOp(op, left, op.value, right));
    }),
    ExpressionGroupLevel("add", (builder) {
      return builder.group()
        ..left(
            (ref1(token, '-').seq(char('{').not()).pick(0) |
                ref1(token, '+').seq(char('{').not()).pick(0)),
            (left, op, right) => BinOp(op, left, op.value, right));
    }),
    ExpressionGroupLevel("compare", (builder) {
      return builder.group()
        ..left(
            ref1(token, '<=') |
                ref1(token, '>=') |
                ref1(token, '!=') |
                ref1(token, '==') |
                ref1(token, '>') |
                ref1(token, '<'),
            (left, op, right) => BinOp(op, left, op.value, right));
    }),
    ExpressionGroupLevel("and", (builder) {
      return builder.group()
        ..left(ref1(token, 'and'), (left, op, right) => BinOp(op, left, op.value, right));
    }),
    ExpressionGroupLevel("or", (builder) {
      return builder.group()
        ..left(ref1(token, 'or'), (left, op, right) => BinOp(op, left, op.value, right));
    }),
  ];

  final Map<String, Parser<Statement>> _statements = {};
  late final Parser<Statement?> _initialStatementParser = super.statement().cast<Statement?>();

  late final AlwaysSettableParser<Statement?> _statementParser =
      AlwaysSettableParser(_initialStatementParser);

  late final Parser _initialExpressionParser = expressionBuilder.build();

  late final AlwaysSettableParser _expressionParser =
      AlwaysSettableParser(_initialExpressionParser);

  SlangParser(super.vm) {
    initExpressionBuilder();
  }

  /// list of all expression group names
  List<String> get expressionGroupNames => _expressionGroupLevels.map((e) => e.name).toList();

  /// list of all primitive expression names
  List<String> get primitiveExpressionNames =>
      _primitiveExpressionLevels.map((e) => e.name).toList();

  /// Adds a new expression group with lower precedence than the one with the name [name]
  void addExpressionGroupAfter(String name, ExpressionGroupLevel level) {
    _expressionGroupLevels.removeWhere((e) => e.name == level.name);
    final index = _expressionGroupLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Expression group $name not found");
    }
    _expressionGroupLevels.insert(index + 1, level);
    _rebuildExpressionParser();
  }

  /// Adds a new expression group with higher precedence than the one with the name [name]
  void addExpressionGroupBefore(String name, ExpressionGroupLevel level) {
    _expressionGroupLevels.removeWhere((e) => e.name == level.name);
    final index = _expressionGroupLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Expression group $name not found");
    }
    _expressionGroupLevels.insert(index, level);
    _rebuildExpressionParser();
  }

  /// Adds a new primitive expression with the lowest priority
  void addPrimitiveExpression(PrimitiveExpressionLevel level) {
    _primitiveExpressionLevels.removeWhere((e) => e.name == level.name);
    _primitiveExpressionLevels.add(level);
    _rebuildExpressionParser();
  }

  /// Add a primitive expression with a priority less than the one with the name [name]
  void addPrimitiveExpressionAfter(String name, PrimitiveExpressionLevel level) {
    final index = _primitiveExpressionLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Primitive expression $name not found");
    }
    _primitiveExpressionLevels.insert(index + 1, level);
    expressionBuilder.primitive(level.parser);
    _rebuildExpressionParser();
  }

  /// Add a primitive expression with a priority greater than the one with the name [name]
  void addPrimitiveExpressionBefore(String name, PrimitiveExpressionLevel level) {
    final index = _primitiveExpressionLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Primitive expression $name not found");
    }
    _primitiveExpressionLevels.insert(index, level);
    _rebuildExpressionParser();
  }

  /// Adds a statement to the parser
  void addStatement(String name, Parser<Statement> statement) {
    _statements[name] = resolve(statement);
    _statementParser
        .set(ChoiceParser<Statement?>([..._statements.values, _initialStatementParser]));
  }

  @override
  Parser args() => super.args().labeled("args").map((args) {
        if (args is List) {
          final normalArgs = args[0] as List<dynamic>;
          final blockArg = args[1] as Block?;
          if (blockArg != null) {
            normalArgs.add(FunctionExpression(blockArg.token, [], blockArg));
          }
          return normalArgs;
        } else {
          final blockArg = args as Block;
          return [FunctionExpression(blockArg.token, [], blockArg)];
        }
      });

  @override
  Parser assignment() => super.assignment().labeled("assignment").map((list) => Assignment(
        list[1],
        list[0],
        list[2],
      ));

  @override
  Parser breakStatement() =>
      super.breakStatement().labeled("breakStatement").map((token) => Break(token));

  @override
  Parser chunk() => super.chunk().labeled("chunk").token().map((token) =>
      Block(token, (token.value[0] as List<dynamic>).cast<Statement?>(), token.value[1]));

  @override
  Parser constPattern() =>
      super.constPattern().labeled("constPattern").map((exp) => ConstPattern(exp.token, exp));

  @override
  Parser doubleLiteral() => super
      .doubleLiteral()
      .labeled("doubleLiteral")
      .map((token) => DoubleLiteral(token, double.parse(token.value)));

  /// Parses an expression.
  /// Includes order of operations.
  ///  ^
  ///  not  - (unary)
  ///  *   /
  ///  +   -
  ///  ..
  ///  <   >   <=  >=  ~=  ==
  ///  and
  ///  or
  @override
  Parser expr() => _expressionParser;

  @override
  Parser exprStatement() => super.exprStatement().labeled("exprStatement").map((value) {
        final AstNode? exp = value[0];
        final List? assignment = value[1];
        if (assignment != null) {
          if (exp is! Assignable) {
            throw Exception("Invalid assignment: $exp is not an assignable expression");
          }
          final token = assignment[0];
          final value = assignment[1];
          return Assignment(token, exp! as Exp, value);
        }
        switch (exp) {
          case FunctionCall call:
            return FunctionCallStatement(call.token, call);
          case NullLiteral():
            return null;
          default:
            return exp;
        }
      });

  @override
  Parser falseLiteral() =>
      super.falseLiteral().labeled("falseLiteral").map((token) => FalseLiteral(token));

  @override
  Parser field() => super.field().labeled("field").token().map((token) {
        final list = token.value;
        var key = list[0];
        final value = list[1];
        if (key is Identifier) {
          key = StringLiteral(key.token, key.value);
        }
        return Field(token, key, value);
      });

  @override
  Parser fieldPattern() => super.fieldPattern().labeled("fieldPattern").map((value) {
        final key = value[0];
        final exp = value[1];
        return FieldPattern(key?.token ?? exp.token, key, exp);
      });

  @override
  Parser forInLoop() => super.forInLoop().labeled("forInLoop").map((values) {
        final token = values[0];
        final pattern = values[3];
        final exp = values[5];
        final body = values[7];
        return ForInLoop(token, pattern, exp, body);
      });

  @override
  Parser forLoop() => super.forLoop().labeled("forLoop").cast<List>().map((List values) {
        final token = values[0];
        final body = values[6];
        final head = values.sublist(2, 5).where((value) => value != null).toList();
        // final init = values[2];
        // final condition = values[3];
        // final update = values[4];
        return switch (head) {
          [Statement init, Exp condition, Statement update] =>
            ForLoop(token, init, condition, update, body),
          [Statement init, Exp condition] => ForLoop(token, init, condition, null, body),
          [Exp condition, Statement update] => ForLoop(token, null, condition, update, body),
          [Exp condition] => ForLoop(token, null, condition, null, body),
          _ => throw Exception("Invalid for loop: $head"),
        };

        // return ForLoop(token, init, condition, update, body);
      });

  @override
  Parser functionDefinition() =>
      super.functionDefinition().labeled("functionDefinition").token().map((token) {
        final value = token.value;
        final params = value[1] as List<dynamic>;
        var body = value[3];
        if (body is List) {
          Exp returnExp = body[1];
          body = Block(token, [], ReturnStatement(returnExp.token, returnExp));
        }
        return FunctionExpression(token, params.cast<Identifier>(), body);
      });

  @override
  Parser functionDefinitonStatement() =>
      super.functionDefinitonStatement().labeled("functionDefinitonStatement").map((value) {
        final local = value[0] != null;
        final name = value[2] as Exp;
        final exp = value[3] as FunctionExpression;
        return Declaration(value[1], local, name, exp);
      });

  @override
  Parser identifier() => super
      .identifier()
      .labeled("identifier")
      .map((token) => Identifier(token, token.value))
      .labeled('identifier');

  @override
  Parser identifierAndIndex() =>
      super.identifierAndIndex().labeled("identifierAndIndex").map((list) {
        final identifier = list[0] as Identifier;
        final indices = list[1] as List<dynamic>;

        return indices.fold<Exp>(identifier,
            (left, right) => Index(right[0].token, left, right[0], dotStyle: right[1] == "dot"));
      });

  @override
  Parser ifStatement() => super.ifStatement().labeled("ifStatement").map((values) => IfStatement(
        values[0],
        values[2],
        values[4],
        values[5] == null ? null : values[5][1],
      ));

  @override
  void initExpressionBuilder() {
    for (var level in _primitiveExpressionLevels) {
      expressionBuilder.primitive(level.parser);
    }
    for (var level in _expressionGroupLevels) {
      level.add(expressionBuilder);
    }
  }

  @override
  Parser intLiteral() => super
      .intLiteral()
      .labeled("intLiteral")
      .map((token) => IntLiteral(token, int.parse(token.value)));

  @override
  Parser localDeclaration() => super.localDeclaration().labeled("localDeclaration").map((list) {
        final local = list[0].value == 'local';
        final name = list[1];
        final assignment = list[2];
        return Declaration(list[0], local, name, assignment?[1]);
      });

  @override
  Parser nameAndArgs() => super.nameAndArgs().labeled("nameAndArgs").token().map((token) {
        final value = token.value;
        final name = value[0];
        final args = value[1];
        return [name, args, token];
      });

  @override
  Parser nullLiteral() =>
      super.nullLiteral().labeled("nullLiteral").map((token) => NullLiteral(token));

  @override
  Parser patternAssignmentExp() =>
      super.patternAssignmentExp().labeled("patternAssignmentExp").map((value) {
        final pattern = value[1];
        final exp = value[3];
        return LetExp(value[0], pattern, exp);
      });

  @override
  Parser quote() => super.quote().labeled("quote").token().map((token) {
        final body = token.value as List<dynamic>;
        final type;
        final ast;
        if (body.length == 3) {
          type = body[0].value;
          ast = body[2];
        } else {
          type = "expr";
          ast = body[1];
        }
        return Quote(token, type, ast);
      });

  @override
  Parser returnStatement() => super
      .returnStatement()
      .labeled("returnStatement")
      .map((list) => ReturnStatement(list[0], list[1]));

  @override
  Parser start() => super
      .start()
      .labeled("start")
      .cast<Block>()
      .map((block) => SlangConstantExpressionOptimizer().visit(block));

  @override
  Parser statement() => _statementParser;

  @override
  Parser stringLiteral() => super.stringLiteral().map((token) => StringLiteral(token, token.value));

  @override
  Parser tableLiteral() => super
      .tableLiteral()
      .castList<Field>()
      .token()
      .map((token) => TableLiteral(token, token.value));

  @override
  Parser tablePattern() => super.tablePattern().labeled("tablePattern").map((value) {
        final Identifier? type = value[0];
        final fields = value[2] as SeparatedList;
        final values = fields.elements;
        return TablePattern(value[1], values.cast<FieldPattern>(), type: type?.value);
      });

  @override
  Parser trueLiteral() =>
      super.trueLiteral().labeled("trueLiteral").map((token) => TrueLiteral(token));

  @override
  Parser varPattern() => super.varPattern().labeled("varPattern").map((value) {
        final isLocal = value[0] != null;
        final name = value[1];
        final canBeNull = value[2] != null;
        return VarPattern(name.token, name, isLocal: isLocal, canBeNull: canBeNull);
      });

  /// Rebuilds the current expression parser
  void _rebuildExpressionParser() {
    expressionBuilder = ExpressionBuilder();
    for (var level in _primitiveExpressionLevels) {
      expressionBuilder.primitive(level.parser);
    }
    for (var level in _expressionGroupLevels) {
      level.add(expressionBuilder);
    }
    _expressionParser.set(resolve(expressionBuilder.build()));
  }
}

extension AlwaysSettableParserExtension<R> on Parser<R> {
  /// Returns a parser that points to the receiver, but can be changed to point
  /// to something else at a later point in time.
  ///
  /// For example, the parser `letter().settable()` behaves exactly the same
  /// as `letter()`, but it can be replaced with another parser using
  /// [SettableParser.set].
  @useResult
  AlwaysSettableParser<R> alwaysSettable() => AlwaysSettableParser<R>(this);
}
