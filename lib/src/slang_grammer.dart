import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';

abstract class SlangGrammer extends GrammarDefinition {
  @override
  Parser start() => ref0(chunk).end();

  Parser expr();

  Parser intLiteral() {
    return ((char('-') | char('+')).optional() & digit().plus())
        .flatten("Expected integer")
        .trim();
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

  Parser name() =>
      (letter() & pattern('a-zA-Z0-9_').star()).flatten('Expected name').trim();

  Parser varRef() => ref0(name) & ref0(varSuffix).star();

  Parser varSuffix() =>
      (char('.').trim() & ref0(name).map((name) => StringLiteral(name.value)))
          .pick(1) |
      (char('[').trim() & ref0(expr) & char(']').trim()).pick(1);

  Parser statement() => ref0(assignment) | ref0(ifStatement) | ref0(block);

  Parser assignment() =>
      string('local').optional().trim() &
      ref0(varRef) &
      char('=').trim() &
      ref0(expr).trim();

  Parser ifStatement() =>
      string('if').trim() &
      char('(').trim() &
      ref0(expr) &
      char(')').trim() &
      ref0(statement) &
      (string('else').trim() & ref0(statement)).optional();

  Parser chunk() =>
      (ref0(statement) & char(';').trim().optional())
          .map((value) => value[0])
          .star() &
      (ref0(finalStatement) & char(';').trim().optional())
          .map((value) => value[0])
          .optional();

  Parser block() => (char('{').trim() & ref0(chunk) & char('}').trim()).pick(1);

  Parser finalStatement() => ref0(returnStatement);

  Parser returnStatement() => string('return') & ref0(expr);
}
