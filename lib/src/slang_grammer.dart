import 'package:petitparser/petitparser.dart';

abstract class SlangGrammer extends GrammarDefinition {
  @override
  Parser start() => ref0(block).end();

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

  Parser listLiteral() {
    return (char('{') &
            ref0(field).starSeparated(char(',').trim()) &
            char(',').optional() &
            char('}'))
        .pick(1)
        .map((list) => list.elements);
  }

  Parser field() {
    return (ref0(expr) & char(':').trim()).optional() & ref0(expr);
  }

  Parser name() => (letter() & pattern('a-zA-Z0-9_').star()).flatten('Expected name').trim();

  Parser statement() => ref0(assignment);

  Parser assignment() =>
      string('local').optional().trim() & ref0(name) & char('=').trim() & ref0(expr).trim();

  Parser block() =>
      (ref0(statement) & char(';').trim().optional()).map((value) => value[0]).star() &
      (ref0(finalStatement) & char(';').trim().optional()).map((value) => value[0]).optional();

  Parser finalStatement() => ref0(returnStatement);

  Parser returnStatement() => string('return') & ref0(expr);
}
