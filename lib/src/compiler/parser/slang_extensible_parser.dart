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

enum ExpressionLevels {
  bracket,
  power,
  unary,
  multiply,
  add,
  compare,
  and,
  or,
}

/// Slang parser with options to extend the existing grammar
class SlangExtensibleParser extends SlangParser {
  SlangExtensibleParser(super.vm);

  final List<Parser<Statement>> _statements = [];

  late final Parser<Statement?> _originalStatementParser = super.statement().cast<Statement?>();

  late final AlwaysSettableParser<Statement?> _statementParser =
      AlwaysSettableParser(_originalStatementParser);

  @override
  Parser statement() => _statementParser;

  /// Adds a statement to the parser
  void addStatement(Parser<Statement> statement) {
    _statements.add(resolve(statement));
    _statementParser.set(ChoiceParser<Statement?>([..._statements, _originalStatementParser]));
  }

  void addPrimitive(Parser<Exp> primitive) {
    expressionBuilder.primitive(primitive);
  }
}
