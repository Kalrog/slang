import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';

/// Defines the Slang grammar.
/// Complete parsing is implemented in the [SlangParser].
abstract class SlangGrammar extends GrammarDefinition {
  /// Returns a token parser that will return a single token for the
  /// given [source].
  /// If source is a [String], the token parser will match the string.
  /// If source is a [Parser], the token parser will wrap the parser and
  /// flatten the result into a string stored in a token.
  Parser<Token> token(Object source, [String? message]) {
    if (source is String) {
      return source
          .toParser(message: "Expected: ${message ?? source}")
          .token()
          .trim(ref0(space));
    } else if (source is Parser) {
      ArgumentError.checkNotNull(message, 'message');
      return source.flatten(message).token().trim(ref0(space));
    } else {
      throw ArgumentError('Invalid argument: $source');
    }
  }

  /// Returns a parser that consumes comments
  Parser comment() => (string('//') & any().starLazy(char('\n')));

  /// Returns a parser that consumes whitespace
  Parser space() => whitespace() | ref0(comment);

  @override
  Parser start() => ref0(chunk).end();

  /// Parses an expression.
  Parser expr();

  /// Parses an integer literal.
  Parser intLiteral() => ref2(
        token,
        ((char('-') | char('+')).optional() & ref0(number)),
        "int",
      );

  Parser number() => digit().plus();

  Parser doubleLiteral() => ref2(
        token,
        (char('-') | char('+')).optional() &
            ref0(number) &
            char('.') &
            ref0(number),
        "double",
      );

  Parser stringLiteral() {
    return ref2(
        token,
        (char('"') & pattern('^"').star() & char('"'))
            .pick(1)
            .map((value) => value.join()),
        "string");
  }

  Parser trueLiteral() => ref1(token, 'true');

  Parser falseLiteral() => ref1(token, 'false');

  Parser nullLiteral() => ref1(token, 'null');

  Parser listLiteral() {
    return (ref1(token, '{') &
            ref0(field).starSeparated(ref1(token, ',')) &
            ref1(token, ',').optional() &
            ref1(token, '}'))
        .pick(1)
        .map((list) => list.elements);
  }

  Parser field() {
    return ((ref0(expr) & ref1(token, ':')).pick(0) |
                (ref1(token, '[') & ref0(expr) & ref1(token, ']')).pick(1))
            .optional() &
        ref0(expr);
  }

  List<String> keywords = [
    'if',
    'else',
    'for',
    'func',
    'return',
    'local',
    'true',
    'false',
    'null',
    'let',
    'break',
  ];
  Parser name() => ref2(
      token,
      (string('...').optional() &
              pattern('a-zA-Z_') &
              pattern('a-zA-Z0-9_').star())
          .flatten("Expected: identifier")
          .where((name) => !keywords.contains(name)),
      "identifier");

  Parser nameAndArgs() =>
      (ref1(token, ':') & ref0(name)).pick(1).optional() & ref0(args);

  Parser args() =>
      ((ref1(token, '(') &
                  ref0(expr)
                      .starSeparated(ref1(token, ','))
                      .map((list) => list.elements) &
                  ref1(token, ')'))
              .pick(1) &
          ref0(block).optional()) |
      ref0(block);

  Parser varRef() => ref0(name) & ref0(varSuffix).star();

  Parser varSuffix() =>
      ref0(nameAndArgs).star() &
      ((ref1(token, '.') &
                  ref0(name)
                      .token()
                      .map((token) => StringLiteral(token, token.value.value)))
              .pick(1) |
          (ref1(token, '[') & ref0(expr) & ref1(token, ']')).pick(1));

  Parser prefixExpr() => ref0(varRef) & ref0(nameAndArgs).star();
  Parser functionCall() => ref0(varRef) & ref0(nameAndArgs).plus();

  Parser statement() =>
      ref0(assignment) |
      ref0(declaration) |
      ref0(ifStatement) |
      ref0(forLoop) |
      ref0(forInLoop) |
      ref0(block) |
      ref0(functionCall) |
      ref0(functionDefinitonStatement) |
      ref0(breakStatement);

  Parser assignment() => ref0(varRef) & ref1(token, '=') & ref0(expr);

  Parser declaration() =>
      ref1(token, 'local') &
      ref0(name) &
      (ref1(token, '=') & ref0(expr)).optional();

  Parser ifStatement() =>
      ref1(token, 'if') &
      ref1(token, '(') &
      ref0(expr) &
      ref1(token, ')') &
      ref0(statement) &
      (ref1(token, 'else') & ref0(statement)).optional();

  Parser forLoop() =>
      ref1(token, 'for') &
      ref1(token, '(') &
      ((ref0(statement) & ref1(token, ';')).pick(0).optional() &
          ref0(expr) &
          (ref1(token, ';') & ref0(statement)).pick(1).optional()) &
      char(')') &
      ref0(statement);

  Parser forInLoop() =>
      ref1(token, 'for') &
      ref1(token, '(') &
      ref0(slangPattern) &
      ref1(token, 'in') &
      ref0(expr) &
      ref1(token, ')') &
      ref0(statement);

  // Combined For Loop grammer:
  // forLoop -> 'for' '(' forContent ')' statement
  // forContent -> (statement ';' basicForTail) |

  Parser functionDefinitonStatement() =>
      ref1(token, 'local').optional() &
      ref1(token, 'func') &
      ref0(varRef) &
      ref0(functionDefinition);

  Parser chunk() =>
      (ref0(statement) & ref1(token, ';').optional())
          .map((value) => value[0])
          .star() &
      (ref0(finalStatement) & ref1(token, ';').optional())
          .map((value) => value[0])
          .optional();

  Parser block() => (ref1(token, '{') & ref0(chunk) & ref1(token, '}')).pick(1);

  Parser breakStatement() => (ref1(token, 'break'));

  Parser finalStatement() => ref0(returnStatement);

  Parser returnStatement() => ref1(token, 'return') & ref0(expr);

  /// func(args)body | func(args) => body
  Parser functionExpression() =>
      (ref1(token, 'func') & ref0(functionDefinition)).pick(1);

  Parser functionDefinition() =>
      ref1(token, '(') &
      ref0(params) &
      ref1(token, ')') &
      (ref0(block) | (ref1(token, '=>') & ref0(expr)));

  Parser params() =>
      ref0(name).starSeparated(ref1(token, ',')).map((list) => list.elements);

  Parser slangPattern() =>
      ref0(tablePattern) | ref0(constPattern) | ref0(varPattern);

  Parser tablePattern() =>
      ref1(token, '{') &
      ref0(fieldPattern).starSeparated(ref1(token, ',')) &
      ref1(token, '}');

  Parser fieldPattern() =>
      ((ref0(name) & ref1(token, ':')).pick(0) |
              (ref1(token, '[') &
                      ref0(expr) &
                      ref1(token, ']') &
                      ref1(token, ':'))
                  .pick(1))
          .map((exp) {
        if (exp is Name) {
          return StringLiteral(exp.token, exp.value);
        } else {
          return exp;
        }
      }).optional() &
      ref0(slangPattern);

  Parser constPattern() =>
      ref0(intLiteral) |
      ref0(doubleLiteral) |
      ref0(stringLiteral) |
      ref0(trueLiteral) |
      ref0(falseLiteral) |
      ref0(nullLiteral);

  Parser varPattern() =>
      ref1(token, 'local').optional() &
      ref0(name) &
      ref1(token, '?').optional();

  Parser patternAssignmentExp() =>
      ref1(token, "let") & ref0(slangPattern) & ref1(token, '=') & ref0(expr);
}
