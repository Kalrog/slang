import 'package:meta/meta.dart';
import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/parser/slang_parser.dart';

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

/// A parser that is not defined, but that can be set at a later
/// point in time.
class AlwaysSettableParser<R> extends DelegateParser<R, R> {
  AlwaysSettableParser(super.delegate);

  /// Sets the receiver to delegate to [parser].
  void set(Parser<R> parser) {
    delegate = parser;
  }

  @override
  Result<R> parseOn(Context context) => delegate.parseOn(context);

  @override
  int fastParseOn(String buffer, int position) => delegate.fastParseOn(buffer, position);

  @override
  AlwaysSettableParser<R> copy() => AlwaysSettableParser<R>(delegate);
}

class ExpressionGroupLevel {
  final String name;
  final ExpressionGroup Function(ExpressionBuilder builder) add;

  ExpressionGroupLevel(this.name, this.add);
}

class PrimitiveExpressionLevel {
  final String name;
  final Parser parser;

  PrimitiveExpressionLevel(this.name, this.parser);
}

/// Slang parser with options to extend the existing grammar
class SlangExtensibleParser extends SlangParser {
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
    PrimitiveExpressionLevel("listLiteral", ref0(listLiteral)),
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

  SlangExtensibleParser(super.vm);

  @override
  void initExpressionBuilder() {
    for (var level in _primitiveExpressionLevels) {
      expressionBuilder.primitive(level.parser);
    }
    for (var level in _expressionGroupLevels) {
      level.add(expressionBuilder);
    }
  }

  final List<Parser<Statement>> _statements = [];

  late final Parser<Statement?> _initialStatementParser = super.statement().cast<Statement?>();

  late final AlwaysSettableParser<Statement?> _statementParser =
      AlwaysSettableParser(_initialStatementParser);

  late final Parser _initialExpressionParser = super.expr();

  late final AlwaysSettableParser _expressionParser =
      AlwaysSettableParser(_initialExpressionParser);

  @override
  Parser statement() => _statementParser;

  @override
  Parser expr() => _expressionParser;

  /// Adds a statement to the parser
  void addStatement(Parser<Statement> statement) {
    _statements.add(resolve(statement));
    _statementParser.set(ChoiceParser<Statement?>([..._statements, _initialStatementParser]));
  }

  void rebuildExpressionParser() {
    expressionBuilder = ExpressionBuilder();
    for (var level in _primitiveExpressionLevels) {
      expressionBuilder.primitive(level.parser);
    }
    for (var level in _expressionGroupLevels) {
      level.add(expressionBuilder);
    }
    _expressionParser.set(resolve(expressionBuilder.build()));
  }

  void addPrimitiveExpressionAfter(String name, PrimitiveExpressionLevel level) {
    final index = _primitiveExpressionLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Primitive expression $name not found");
    }
    _primitiveExpressionLevels.insert(index + 1, level);
    expressionBuilder.primitive(level.parser);
    rebuildExpressionParser();
  }

  void addPrimitiveExpressionBefore(String name, PrimitiveExpressionLevel level) {
    final index = _primitiveExpressionLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Primitive expression $name not found");
    }
    _primitiveExpressionLevels.insert(index, level);
    rebuildExpressionParser();
  }

  void addPrimitiveExpression(PrimitiveExpressionLevel level) {
    _primitiveExpressionLevels.add(level);
    rebuildExpressionParser();
  }

  void addExpressionGroupAfter(String name, ExpressionGroupLevel level) {
    final index = _expressionGroupLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Expression group $name not found");
    }
    _expressionGroupLevels.insert(index + 1, level);
    rebuildExpressionParser();
  }

  void addExpressionGroupBefore(String name, ExpressionGroupLevel level) {
    final index = _expressionGroupLevels.indexWhere((element) => element.name == name);
    if (index == -1) {
      throw ArgumentError("Expression group $name not found");
    }
    _expressionGroupLevels.insert(index, level);
    rebuildExpressionParser();
  }

  List<String> get primitiveExpressionNames =>
      _primitiveExpressionLevels.map((e) => e.name).toList();

  List<String> get expressionGroupNames => _expressionGroupLevels.map((e) => e.name).toList();
}
