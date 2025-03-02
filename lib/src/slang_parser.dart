import 'package:petitparser/petitparser.dart';
import 'package:slang/src/ast.dart';
import 'package:slang/src/slang_grammer.dart';

class SlangParser extends SlangGrammar {
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
  Parser expr() {
    final builder = ExpressionBuilder<Exp>();
    builder.primitive(ref0(intLiteral).cast<Exp>());
    builder.primitive(ref0(stringLiteral).cast<Exp>());
    builder.primitive(ref0(trueLiteral).cast<Exp>());
    builder.primitive(ref0(falseLiteral).cast<Exp>());
    builder.primitive(ref0(listLiteral).cast<Exp>());
    builder.primitive(ref0(functionExpression).cast<Exp>());
    builder.primitive(ref0(prefixExpr).cast<Exp>());
    builder.group().wrapper(
        ref1(token, '('), ref1(token, ')'), (left, value, right) => value);
    // builder.group().right(ref1(token,'^'), BinOp.new);
    builder.group().right(ref1(token, '^'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    builder.group().prefix(ref1(token, '-') | ref1(token, 'not'),
        (opToken, exp) => UnOp(opToken, opToken.value, exp));
    builder.group().left(ref1(token, '*') | ref1(token, '/') | ref1(token, '%'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));

    builder.group().left((ref1(token, '-') | ref1(token, '+')),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    builder.group().left(
        ref1(token, '<=') |
            ref1(token, '>=') |
            ref1(token, '!=') |
            ref1(token, '==') |
            ref1(token, '>') |
            ref1(token, '<'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    builder.group().left(ref1(token, 'and'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    builder.group().left(ref1(token, 'or'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));

    return builder.build().labeled('expression');
  }

  @override
  Parser intLiteral() => super
      .intLiteral()
      .map((token) => IntLiteral(token, int.parse(token.value)));

  @override
  Parser stringLiteral() =>
      super.stringLiteral().map((token) => StringLiteral(token, token.value));

  @override
  Parser trueLiteral() =>
      super.trueLiteral().map((token) => TrueLiteral(token));

  @override
  Parser falseLiteral() =>
      super.falseLiteral().map((token) => FalseLiteral(token));

  @override
  Parser nullLiteral() =>
      super.nullLiteral().map((token) => NullLiteral(token));

  @override
  Parser name() => super.name().map((token) => Name(token, token.value));

  @override
  Parser chunk() => super.chunk().token().map((token) => Block(token,
      (token.value[0] as List<dynamic>).cast<Statement>(), token.value[1]));

  @override
  Parser returnStatement() =>
      super.returnStatement().map((list) => ReturnStatement(list[0], list[1]));

  @override
  Parser assignment() => super.assignment().map((list) => Assignment(
        list[2],
        list[1],
        list[3],
        isLocal: list[0] != null,
      ));

  @override
  Parser listLiteral() => super
      .listLiteral()
      .castList<Field>()
      .token()
      .map((token) => TableLiteral(token, token.value));

  @override
  Parser field() => super.field().token().map((token) {
        final list = token.value;
        var key = list[0]?[0];
        final value = list[1];
        if (key is Name) {
          key = StringLiteral(key.token, key.value);
        }
        return Field(token, key, value);
      });

  @override
  Parser varRef() => super.varRef().map((list) {
        var name = list[0];
        final suffixes = list[1] as List<dynamic>;
        return suffixes.fold(name, (exp, suffix) {
          final nameAndArgs = suffix[0];
          final index = suffix[1];
          final token = suffix[2];

          exp = nameAndArgs.fold(exp, (exp, nameAndArgs) {
            final name = nameAndArgs[0];
            final args = nameAndArgs[1];
            final token = nameAndArgs[2];
            return FunctionCall(
                token, exp, name, (args as List<dynamic>).cast<Exp>());
          });
          exp = Index(token, exp, index);
          return exp;
        });
      }).labeled('var ref');

  @override
  Parser prefixExpr() => super.prefixExpr().map((value) {
        var exp = value[0];
        final nameAndArgs = value[1] as List<dynamic>;
        return nameAndArgs.fold(exp, (exp, nameAndArgs) {
          final name = nameAndArgs[0];
          final args = nameAndArgs[1];
          final token = nameAndArgs[2];

          return FunctionCall(
              token, exp, name, (args as List<dynamic>).cast<Exp>());
        });
      });

  @override
  Parser functionCall() => super.functionCall().token().map((token) {
        final value = token.value;
        var exp = value[0];
        final nameAndArgs = value[1] as List<dynamic>;
        exp = nameAndArgs.fold(exp, (exp, nameAndArgs) {
          final name = nameAndArgs[0];
          final args = nameAndArgs[1];
          final token = nameAndArgs[2];

          return FunctionCall(
              token, exp, name, (args as List<dynamic>).cast<Exp>());
        });
        return FunctionCallStatement(token, exp);
      });

  @override
  Parser nameAndArgs() => super.nameAndArgs().token().map((token) {
        final value = token.value;
        final name = value[0];
        final args = value[1];
        return [name, args, token];
      });

  @override
  Parser varSuffix() =>
      super.varSuffix().token().map((token) => [...token.value, token]);

  @override
  Parser ifStatement() => super.ifStatement().map((values) => IfStatement(
        values[0],
        values[2],
        values[4],
        values[5] == null ? null : values[5][1],
      ));

  @override
  Parser forLoop() => super.forLoop().map((values) {
        final token = values[0];
        final head = values[2] as List<dynamic>;
        final init = head[0];
        final condition = head[1];
        final update = head[2];
        final body = values[4];
        return ForLoop(token, init, condition, update, body);
      });

  @override
  Parser functionDefinition() =>
      super.functionDefinition().token().map((token) {
        final value = token.value;
        final params = value[1] as List<dynamic>;
        var body = value[3];
        if (body is String) {
          Exp returnExp = value[4];
          body = Block(token, [], ReturnStatement(returnExp.token, returnExp));
        }
        return FunctionExpression(token, params.cast<Name>(), body);
      }).labeled('function expression');

  @override
  Parser functionDefinitonStatement() =>
      super.functionDefinitonStatement().map((value) {
        final local = value[0] != null;
        final name = value[2] as Exp;
        final exp = value[3] as FunctionExpression;
        return Assignment(value[1], name, exp, isLocal: local);
      });
}
