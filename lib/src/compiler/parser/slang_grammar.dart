import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/ast_converter.dart';
import 'package:slang/src/compiler/codegen/slang_code_generator.dart';
import 'package:slang/src/slang_vm.dart';

/// Defines the Slang grammar.
/// Complete parsing is implemented in the [SlangParser].
abstract class SlangGrammar extends GrammarDefinition {
  final SlangVm vm;

  SlangGrammar(this.vm);

  /// Returns a token parser that will return a single token for the
  /// given [source].
  /// If source is a [String], the token parser will match the string.
  /// If source is a [Parser], the token parser will wrap the parser and
  /// flatten the result into a string stored in a token.
  Parser<Token> token(Object source, [String? message]) {
    if (source is String) {
      return source.toParser(message: "Expected: ${message ?? source}").token().trim(ref0(space));
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
        (char('-') | char('+')).optional() & ref0(number) & char('.') & ref0(number),
        "double",
      );

  Parser stringLiteral() => ref0(multilineStringLiteral) | ref0(doubleQuotedStringLiteral);

  Parser doubleQuotedStringLiteral() =>
      (char('"') & ref0(slangChar).starLazy(char('"')).map((value) => value.join()) & char('"'))
          .pick(1)
          .token();

  Parser multilineStringLiteral() => (string('"""') &
          (ref0(slangChar) | char('\n')).starLazy(string('"""')).map((value) => value.join()) &
          string('"""'))
      .pick(1)
      .token();

  Parser slangChar() => ref0(validEscape) | char('\n').neg();

  Parser validEscape() => (char('\\') &
          (char('"') |
              char('\\') |
              char('n') |
              char('r') |
              char('t') |
              char('b') |
              char('f') |
              char('v')))
      .flatten();

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
    return ((ref0(identifier) & ref1(token, ':')).pick(0) |
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

  Parser identifier() => ref2(
      token,
      (string('...').optional() & pattern('a-zA-Z_') & pattern('a-zA-Z0-9_').star())
          .flatten("Expected: identifier")
          .where((name) => !keywords.contains(name)),
      "identifier");

  Parser identifierAndIndex() =>
      ref0(identifier) &
      ((ref1(token, '[') & ref0(expr) & ref1(token, ']')).pick(1).map((e) => [e, "bracket"]) |
              (ref1(token, '.') &
                      ref0(identifier).cast<Identifier>().map<Exp>(StringLiteral.fromIdentifier))
                  .pick(1)
                  .map((e) => [e, "dot"]))
          .star();

  Parser nameAndArgs() => (ref1(token, ':') & ref0(identifier)).pick(1).optional() & ref0(args);

  Parser args() =>
      ((ref1(token, '(') &
                  ref0(expr).starSeparated(ref1(token, ',')).map((list) => list.elements) &
                  ref1(token, ')'))
              .pick(1) &
          ref0(block).optional()) |
      ref0(block);

  Parser statement() => expressionOrStatement().where((value) => value is Statement?);

  Parser expressionOrStatement() =>
      ref0(localDeclaration) |
      ref0(ifStatement) |
      ref0(forLoop) |
      ref0(forInLoop) |
      ref0(block) |
      ref0(functionDefinitonStatement) |
      ref0(exprStatement);

  Parser exprStatement() => ref0(expr) & (ref1(token, '=') & ref0(expr)).optional();

  Parser assignment() => ref0(expr) & ref1(token, '=') & ref0(expr);

  Parser localDeclaration() =>
      ref1(token, 'local') & ref0(expr) & (ref1(token, '=') & ref0(expr)).optional();

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
      ref0(expressionOrStatement) &
      (ref1(token, ';') & ref0(expressionOrStatement)).pick(1).optional() &
      (ref1(token, ';') & ref0(statement)).pick(1).optional() &
      char(')') &
      ref0(statement);

  Parser forInLoop() =>
      ref1(token, 'for') &
      ref1(token, '(') &
      ref1(token, 'let') &
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
      ref0(identifierAndIndex) &
      ref0(functionDefinition);

  Parser chunk() =>
      (ref0(statement) & ref1(token, ';').optional()).pick(0).star() &
      (ref0(finalStatement) & ref1(token, ';').optional()).pick(0).optional();

  Parser block() => (ref1(token, '{') & ref0(chunk) & ref1(token, '}')).pick(1);

  Parser breakStatement() => (ref1(token, 'break'));

  Parser finalStatement() => ref0(returnStatement) | ref0(breakStatement);

  Parser returnStatement() => ref1(token, 'return') & ref0(expr);

  /// func(args)body | func(args) => body
  Parser functionExpression() => (ref1(token, 'func') & ref0(functionDefinition)).pick(1);

  Parser functionDefinition() =>
      ref1(token, '(') &
      ref0(params) &
      ref1(token, ')') &
      (ref0(block) | (ref1(token, '=>') & ref0(expr)));

  Parser params() => ref0(identifier).starSeparated(ref1(token, ',')).map((list) => list.elements);

  Parser slangPattern() => ref0(tablePattern) | ref0(constPattern) | ref0(varPattern);

  Parser tablePattern() =>
      (ref1(token, "'") & ref0(identifier)).pick(1).optional() &
      ref1(token, '{') &
      ref0(fieldPattern).starSeparated(ref1(token, ',')) &
      ref1(token, '}');

  Parser fieldPattern() =>
      ((ref0(identifier) & ref1(token, ':')).pick(0) |
              (ref1(token, '[') & ref0(expr) & ref1(token, ']') & ref1(token, ':')).pick(1))
          .map((exp) {
        if (exp is Identifier) {
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
      ref1(token, 'local').optional() & ref0(identifier) & ref1(token, '?').optional();

  Parser patternAssignmentExp() =>
      ref1(token, "let") & ref0(slangPattern) & ref1(token, '=') & ref0(expr);

  bool inQuote = false;

  Parser quote() => (ref1(token, '+') &
          ref1(token, '{') &
          ref0(quoteBody).callCC((continuation, context) {
            final prevInQuote = inQuote;
            inQuote = true;
            final result = continuation(context);
            inQuote = prevInQuote;
            return result;
          }) &
          ref1(token, '}'))
      .pick(2);

  Parser unquote() => (ref1(token, '-') &
          ref1(token, '{') &
          ref0(quoteBody).token().callCC((continuation, context) {
            final tokenResult = continuation(context);
            if (tokenResult is Failure) {
              return tokenResult;
            }
            final token = tokenResult.value;
            final body = token.value as List<dynamic>;
            dynamic type;
            dynamic ast;
            if (body.length == 2) {
              type = 'expr';
              ast = body[1];
            } else {
              type = body[0].value;
              ast = body[2];
            }

            if (inQuote) {
              // we just want the contents of this to be spliced into the quote, so we can just continue here
              return context.success(Unquote(token, type, ast), context.position + token.length);
            } else {
              if (type != 'expr' && type != 'block') {
                return context
                    .failure("Unquote outside of quote can only be used with expr or block");
              }
              // we are not inside a quote, we want to parse this execute the code inside the unquote and put the resulting ast as the result
              if (type == 'expr') {
                ast = Block(ast.token, [], ReturnStatement(ast.token, ast));
              }
              final function = SlangCodeGenerator().generate(ast, "unquote");
              vm.load(function);
              vm.call(0);
              vm.run();
              final result = vm.toAny(-1);
              vm.pop();
              if (result == null) {
                return context.success(NullLiteral(ast.token), context.position + token.length);
              }
              final outAst = decodeAst<Statement?>(result);
              return context.success(outAst, context.position + token.length);
            }
          }) &
          ref1(token, '}'))
      .pick(2);

  Parser quoteBody() =>
      (ref1(token, 'id') & ref1(token, ':') & ref0(identifier)) |
      (ref1(token, 'block') & ref1(token, ':') & ref0(chunk)) |
      (ref1(token, 'stat') & ref1(token, ':') & ref0(statement)) |
      ((ref1(token, 'expr') & ref1(token, ':')).optional() & ref0(expr));
}
