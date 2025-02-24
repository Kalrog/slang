import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';

abstract class SlangGrammar extends GrammarDefinition {
  @override
  Parser start() => ref0(chunk).end();

  Parser expr();

  Parser intLiteral() {
    return ((char('-') | char('+')).optional() & digit().plus()).flatten("Expected integer").trim();
  }

  Parser stringLiteral() {
    return (char('"') & pattern('^"').star() & char('"'))
        .pick(1)
        .map((value) => value.join())
        .trim();
  }

  Parser trueLiteral() => string('true').trim();

  Parser falseLiteral() => string('false').trim();

  Parser listLiteral() {
    return (char('{').trim() &
            ref0(field).starSeparated(char(',').trim()) &
            char(',').trim().optional() &
            char('}').trim())
        .pick(1)
        .map((list) => list.elements);
  }

  Parser field() {
    return (ref0(expr) & char(':').trim()).trim().optional() & ref0(expr);
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
  ];
  Parser name() => (letter() & pattern('a-zA-Z0-9_').star())
      .flatten('Expected name')
      .trim()
      .where((name) => !keywords.contains(name));

  Parser nameAndArgs() => (char(':') & ref0(name)).pick(1).optional() & ref0(args);

  Parser args() => (char('(').trim() &
          ref0(expr).starSeparated(char(',').trim()).map((list) => list.elements) &
          char(')').trim())
      .pick(1);

  Parser varRef() => ref0(name) & ref0(varSuffix).star();

  Parser varSuffix() =>
      ref0(nameAndArgs).star() &
      ((char('.').trim() &
                  ref0(name).token().map((token) => StringLiteral(token, token.value.value)))
              .pick(1) |
          (char('[').trim() & ref0(expr) & char(']').trim()).pick(1));

  Parser prefixExpr() => ref0(varRef) & ref0(nameAndArgs).star();
  Parser functionCall() => ref0(varRef) & ref0(nameAndArgs).plus();

  Parser statement() =>
      ref0(assignment) |
      ref0(ifStatement) |
      ref0(forLoop) |
      ref0(block) |
      ref0(functionCall) |
      ref0(functionDefinitonStatement);

  Parser assignment() =>
      string('local').trim().optional() & ref0(varRef) & char('=').trim() & ref0(expr).trim();

  Parser ifStatement() =>
      string('if').trim() &
      char('(').trim() &
      ref0(expr) &
      char(')').trim() &
      ref0(statement) &
      (string('else').trim() & ref0(statement)).optional();

  Parser forLoop() =>
      string('for').trim() &
      char('(').trim() &
      ((ref0(statement) & char(';').trim()).pick(0).optional() &
          ref0(expr) &
          (char(';').trim() & ref0(statement)).pick(1).optional()) &
      char(')').trim() &
      ref0(statement);

  Parser functionDefinitonStatement() =>
      string('local').trim().optional() &
      string('func').trim() &
      ref0(varRef) &
      ref0(functionDefinition);

  Parser chunk() =>
      (ref0(statement) & char(';').trim().optional()).map((value) => value[0]).star() &
      (ref0(finalStatement) & char(';').trim().optional()).map((value) => value[0]).optional();

  Parser block() => (char('{').trim() & ref0(chunk) & char('}').trim()).pick(1);

  Parser finalStatement() => ref0(returnStatement);

  Parser returnStatement() => string('return') & ref0(expr);

  /// func(args)body | func(args) => body
  Parser functionExpression() => (string('func').trim() & ref0(functionDefinition)).pick(1);

  Parser functionDefinition() =>
      (char('(').trim() & ref0(params) & char(')').trim() & ref0(block)) |
      (char('(').trim() & ref0(params) & char(')').trim() & string('=>').trim() & ref0(expr));

  Parser params() => ref0(name).starSeparated(char(',').trim()).map((list) => list.elements);
}
