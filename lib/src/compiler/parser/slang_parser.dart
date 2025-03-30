import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/codegen/optimizer.dart';
import 'package:slang/src/compiler/parser/slang_grammar.dart';

class SlangParser extends SlangGrammar {
  ExpressionBuilder expressionBuilder = ExpressionBuilder();

  SlangParser(super.vm) {
    initExpressionBuilder();
  }
  @override
  Parser start() => super
      .start()
      .labeled("start")
      .cast<Block>()
      .map((block) => SlangConstantExpressionOptimizer().visit(block));

  void initExpressionBuilder() {
    expressionBuilder.primitive(ref0(unquote));
    expressionBuilder.primitive(ref0(quote).cast<Exp>());
    expressionBuilder.primitive(ref0(identifier).cast<Exp>());
    expressionBuilder.primitive(ref0(doubleLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(intLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(stringLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(trueLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(falseLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(nullLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(patternAssignmentExp).cast<Exp>());
    expressionBuilder.primitive(ref0(listLiteral).cast<Exp>());
    expressionBuilder.primitive(ref0(functionExpression).cast<Exp>());
    // expressionBuilder.primitive(ref0(prefixExpr).cast<Exp>());
    expressionBuilder
        .group()
        .wrapper(ref1(token, '('), ref1(token, ')'), (left, value, right) => value);
    expressionBuilder.group()
      ..postfix(ref1(token, '.') & ref0(identifier), (left, op) {
        final ident = op[1] as Identifier;
        return Index(op[0], left, StringLiteral(ident.token, ident.value), dotStyle: true);
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
    // builder.group().right(ref1(token,'^'), BinOp.new);
    expressionBuilder.group().right(
        ref1(token, '^'), (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    expressionBuilder.group().prefix(
        ref1(token, '-').seq(char('{').not()).pick(0) | ref1(token, 'not'),
        (opToken, exp) => UnOp(opToken, opToken.value, exp));
    expressionBuilder.group().left(ref1(token, '*') | ref1(token, '/') | ref1(token, '%'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    expressionBuilder.group().left(
        (ref1(token, '-').seq(char('{').not()).pick(0) |
            ref1(token, '+').seq(char('{').not()).pick(0)),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    expressionBuilder.group().left(
        ref1(token, '<=') |
            ref1(token, '>=') |
            ref1(token, '!=') |
            ref1(token, '==') |
            ref1(token, '>') |
            ref1(token, '<'),
        (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    expressionBuilder.group().left(
        ref1(token, 'and'), (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
    expressionBuilder.group().left(
        ref1(token, 'or'), (left, opToken, right) => BinOp(opToken, left, opToken.value, right));
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
  Parser intLiteral() => super
      .intLiteral()
      .labeled("intLiteral")
      .map((token) => IntLiteral(token, int.parse(token.value)));

  @override
  Parser doubleLiteral() => super
      .doubleLiteral()
      .labeled("doubleLiteral")
      .map((token) => DoubleLiteral(token, double.parse(token.value)));

  @override
  Parser stringLiteral() => super.stringLiteral().map((token) => StringLiteral(token, token.value));

  @override
  Parser trueLiteral() =>
      super.trueLiteral().labeled("trueLiteral").map((token) => TrueLiteral(token));

  @override
  Parser falseLiteral() =>
      super.falseLiteral().labeled("falseLiteral").map((token) => FalseLiteral(token));

  @override
  Parser nullLiteral() =>
      super.nullLiteral().labeled("nullLiteral").map((token) => NullLiteral(token));

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
  Parser chunk() => super.chunk().labeled("chunk").token().map((token) =>
      Block(token, (token.value[0] as List<dynamic>).cast<Statement?>(), token.value[1]));

  @override
  Parser returnStatement() => super
      .returnStatement()
      .labeled("returnStatement")
      .map((list) => ReturnStatement(list[0], list[1]));

  @override
  Parser assignment() => super.assignment().labeled("assignment").map((list) => Assignment(
        list[1],
        list[0],
        list[2],
      ));

  @override
  Parser localDeclaration() => super.localDeclaration().labeled("localDeclaration").map((list) {
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
  Parser nameAndArgs() => super.nameAndArgs().labeled("nameAndArgs").token().map((token) {
        final value = token.value;
        final name = value[0];
        final args = value[1];
        return [name, args, token];
      });

  @override
  Parser ifStatement() => super.ifStatement().labeled("ifStatement").map((values) => IfStatement(
        values[0],
        values[2],
        values[4],
        values[5] == null ? null : values[5][1],
      ));

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
  Parser forInLoop() => super.forInLoop().labeled("forInLoop").map((values) {
        final token = values[0];
        final pattern = values[2];
        final exp = values[4];
        final body = values[6];
        return ForInLoop(token, pattern, exp, body);
      });

  @override
  Parser breakStatement() =>
      super.breakStatement().labeled("breakStatement").map((token) => Break(token));

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
  Parser varPattern() => super.varPattern().labeled("varPattern").map((value) {
        final isLocal = value[0] != null;
        final name = value[1];
        final canBeNull = value[2] != null;
        return VarPattern(name.token, name, isLocal: isLocal, canBeNull: canBeNull);
      });

  @override
  Parser constPattern() =>
      super.constPattern().labeled("constPattern").map((exp) => ConstPattern(exp.token, exp));

  @override
  Parser fieldPattern() => super.fieldPattern().labeled("fieldPattern").map((value) {
        final key = value[0];
        final exp = value[1];
        return FieldPattern(key?.token ?? exp.token, key, exp);
      });

  @override
  Parser tablePattern() => super.tablePattern().labeled("tablePattern").map((value) {
        final fields = value[1] as SeparatedList;
        final values = fields.elements;
        return TablePattern(value[0], values.cast<FieldPattern>());
      });

  @override
  Parser patternAssignmentExp() =>
      super.patternAssignmentExp().labeled("patternAssignmentExp").map((value) {
        final pattern = value[1];
        final exp = value[3];
        return PatternAssignmentExp(value[0], pattern, exp);
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
}
