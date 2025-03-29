import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/codegen/optimizer.dart';
import 'package:slang/src/compiler/parser/slang_grammar.dart';

class SlangParser extends SlangGrammar {
  ExpressionBuilder<Exp> expressionBuilder = ExpressionBuilder<Exp>();
  List<ExpressionGroup<Exp>> expressionGroups = [];

  SlangParser(super.vm) {
    initExpressionBuilder();
  }
  @override
  Parser start() =>
      super.start().cast<Block>().map((block) => SlangConstantExpressionOptimizer().visit(block));

  void initExpressionBuilder() {
    expressionBuilder.primitive(ref0(unquoteExpression).cast<Exp>());
    expressionBuilder.primitive(ref0(doubleLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(intLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(stringLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(trueLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(falseLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(nullLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(patternAssignmentExp).cast<Exp>());
    expressionBuilder.primitive(ref0(listLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(functionExpression).cast<Exp>());
    expressionBuilder.primitive(ref0(prefixExpr).cast<Exp>());
    expressionBuilder.primitive(ref0(quote).cast<Exp>());
    expressionBuilder
        .group()
        .wrapper(ref1(token, '('), ref1(token, ')'), (left, value, right) => value);
    // builder.group().right(ref1(token,'^'), BinOp.new);
    expressionGroups.add(expressionBuilder.group()
      ..right(
          ref1(token, '^'), (left, opToken, right) => BinOp(opToken, left, opToken.value, right)));
    expressionGroups.add(expressionBuilder.group()
      ..prefix(ref1(token, '-').seq(char('{').not()) | ref1(token, 'not'),
          (opToken, exp) => UnOp(opToken, opToken.value, exp)));
    expressionGroups.add(expressionBuilder.group()
      ..left(ref1(token, '*') | ref1(token, '/') | ref1(token, '%'),
          (left, opToken, right) => BinOp(opToken, left, opToken.value, right)));
    expressionGroups.add(expressionBuilder.group()
      ..left((ref1(token, '-') | ref1(token, '+')),
          (left, opToken, right) => BinOp(opToken, left, opToken.value, right)));
    expressionGroups.add(expressionBuilder.group()
      ..left(
          ref1(token, '<=') |
              ref1(token, '>=') |
              ref1(token, '!=') |
              ref1(token, '==') |
              ref1(token, '>') |
              ref1(token, '<'),
          (left, opToken, right) => BinOp(opToken, left, opToken.value, right)));
    expressionGroups.add(expressionBuilder.group()
      ..left(ref1(token, 'and'),
          (left, opToken, right) => BinOp(opToken, left, opToken.value, right)));
    expressionGroups.add(expressionBuilder.group()
      ..left(
          ref1(token, 'or'), (left, opToken, right) => BinOp(opToken, left, opToken.value, right)));
  }

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
    return expressionBuilder.build().labeled('expression');
  }

  @override
  Parser intLiteral() =>
      super.intLiteral().map((token) => IntLiteral(token, int.parse(token.value)));

  @override
  Parser doubleLiteral() =>
      super.doubleLiteral().map((token) => DoubleLiteral(token, double.parse(token.value)));

  @override
  Parser stringLiteral() => super
      .stringLiteral()
      .map((token) => StringLiteral(token, token.value.substring(1, token.value.length - 1)));

  @override
  Parser trueLiteral() => super.trueLiteral().map((token) => TrueLiteral(token));

  @override
  Parser falseLiteral() => super.falseLiteral().map((token) => FalseLiteral(token));

  @override
  Parser nullLiteral() => super.nullLiteral().map((token) => NullLiteral(token));

  @override
  Parser textIdentifier() => super.textIdentifier().map((token) => Identifier(token, token.value));

  @override
  Parser chunk() => super.chunk().token().map((token) =>
      Block(token, (token.value[0] as List<dynamic>).cast<Statement?>(), token.value[1]));

  @override
  Parser returnStatement() =>
      super.returnStatement().map((list) => ReturnStatement(list[0], list[1]));

  @override
  Parser assignment() => super.assignment().map((list) => Assignment(
        list[1],
        list[0],
        list[2],
      ));

  @override
  Parser declaration() => super.declaration().map((list) {
        final local = list[0].value == 'local';
        final name = list[1];
        final assignment = list[2];
        return Declaration(list[0], local, name, assignment?[1]);
      });

  @override
  Parser listLiteral() => super
      .listLiteral()
      .castList<Field>()
      .token()
      .map((token) => TableLiteral(token, token.value));

  @override
  Parser field() => super.field().token().map((token) {
        final list = token.value;
        var key = list[0];
        final value = list[1];
        if (key is Identifier) {
          key = StringLiteral(key.token, key.value);
        }
        return Field(token, key, value);
      });

  @override
  Parser varRef() => super.varRef().map((list) {
        Exp name = list[0];
        final suffixes = list[1] as List<dynamic>;
        return suffixes.fold(name, _applyVarSuffix);
      }).labeled('var ref');

  Parser unquoteExpression() => super.unquoteExpression().map((list) {
        Exp unquote = list[0];
        final suffix = list[1] as List<dynamic>?;
        if (suffix != null) {
          final varSuffix = suffix[0] as List<dynamic>;
          final nameAndArgs = suffix[1] as List<dynamic>;
          unquote = varSuffix.fold(unquote, _applyVarSuffix);
          unquote = nameAndArgs.fold(unquote, _applyNameAndArgs);
        }
        return unquote;
      });

  @override
  Parser prefixExpr() => super.prefixExpr().map((value) {
        var exp = value[0];
        final nameAndArgs = value[1] as List<dynamic>;
        return nameAndArgs.fold(exp as Exp, _applyNameAndArgs);
      });

  @override
  Parser functionCall() => super.functionCall().token().map((token) {
        final value = token.value;
        var exp = value[0];
        final nameAndArgs = value[1] as List<dynamic>;
        exp = nameAndArgs.fold(exp as Exp, _applyNameAndArgs);
        return FunctionCallStatement(token, exp as FunctionCall);
      });

  @override
  Parser args() => super.args().map((args) {
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
  Parser nameAndArgs() => super.nameAndArgs().token().map((token) {
        final value = token.value;
        final name = value[0];
        final args = value[1];
        return [name, args, token];
      });

  @override
  Parser varSuffix() => super.varSuffix().token().map((token) => [...token.value, token]);

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
  Parser forInLoop() => super.forInLoop().map((values) {
        final token = values[0];
        final pattern = values[2];
        final exp = values[4];
        final body = values[6];
        return ForInLoop(token, pattern, exp, body);
      });

  @override
  Parser breakStatement() => super.breakStatement().map((token) => Break(token));

  @override
  Parser functionDefinition() => super.functionDefinition().token().map((token) {
        final value = token.value;
        final params = value[1] as List<dynamic>;
        var body = value[3];
        if (body is List) {
          Exp returnExp = body[1];
          body = Block(token, [], ReturnStatement(returnExp.token, returnExp));
        }
        return FunctionExpression(token, params.cast<Identifier>(), body);
      }).labeled('function expression');

  @override
  Parser functionDefinitonStatement() => super.functionDefinitonStatement().map((value) {
        final local = value[0] != null;
        final name = value[2] as Exp;
        final exp = value[3] as FunctionExpression;
        return Declaration(value[1], local, name, exp);
      });

  @override
  Parser varPattern() => super.varPattern().map((value) {
        final isLocal = value[0] != null;
        final name = value[1];
        final canBeNull = value[2] != null;
        return VarPattern(name.token, name, isLocal: isLocal, canBeNull: canBeNull);
      });

  @override
  Parser constPattern() => super.constPattern().map((exp) => ConstPattern(exp.token, exp));

  @override
  Parser fieldPattern() => super.fieldPattern().map((value) {
        final key = value[0];
        final exp = value[1];
        return FieldPattern(key?.token ?? exp.token, key, exp);
      });

  @override
  Parser tablePattern() => super.tablePattern().map((value) {
        final fields = value[1] as SeparatedList;
        final values = fields.elements;
        return TablePattern(value[0], values.cast<FieldPattern>());
      });

  @override
  Parser patternAssignmentExp() => super.patternAssignmentExp().map((value) {
        final pattern = value[1];
        final exp = value[3];
        return PatternAssignmentExp(value[0], pattern, exp);
      });

  @override
  Parser quote() => super.quote().token().map((token) {
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
  Parser unquoteStatement() => super.unquoteStatement().map((value) {
        var unquote = value[0];
        final suffix = value[1];
        if (suffix != null) {
          final varSuffix = suffix[0] as List<dynamic>?;

          if (varSuffix != null) {
            unquote = varSuffix.fold(unquote as Exp, _applyVarSuffix);
          }
          final argsOrAssignment = suffix[1];
          switch (argsOrAssignment) {
            case [Token(value: '='), ...]:
              final right = argsOrAssignment[1];
              return Assignment(unquote.token, unquote, right);
            case List<dynamic> args?:
              final nameAndArgs = args;
              unquote = nameAndArgs.fold(unquote as Exp, _applyNameAndArgs);
              return FunctionCallStatement(unquote.token, unquote as FunctionCall);
          }
        }
        return unquote;
      });

  Exp _applyVarSuffix(Exp exp, suffix) {
    final nameAndArgs = suffix[0] as List<dynamic>;
    final index = suffix[1];
    final token = suffix[2];

    exp = nameAndArgs.fold(exp, _applyNameAndArgs);
    exp = Index(token, exp, index);
    return exp;
  }

  Exp _applyNameAndArgs(Exp exp, nameAndArgs) {
    final name = nameAndArgs[0];
    final args = nameAndArgs[1];
    final token = nameAndArgs[2];
    return FunctionCall(token, exp, name, (args as List<dynamic>).cast<Exp>());
  }
}
