import 'package:petitparser/petitparser.dart';
import 'package:slang/src/ast.dart';
import 'package:slang/src/slang_grammer.dart';

class SlangParser extends SlangGrammer {
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
    builder.primitive(ref0(varRef).cast<Exp>());
    builder.group().wrapper(
        char('(').trim(), char(')').trim(), (left, value, right) => value);
    builder.group().right(char('^').trim(), BinOp.new);
    builder.group().prefix(
        (char('-').trim() | string('not').trim()).cast<String>(), UnOp.new);
    builder.group().left(
        (char('*') | char('/') | char('%')).trim().cast<String>(), BinOp.new);
    builder
        .group()
        .left((char('-') | char('+')).trim().cast<String>(), BinOp.new);
    builder.group().left(
        (string('<=').trim() |
                string('>=').trim() |
                string('!=').trim() |
                string('==').trim() |
                string('>').trim() |
                string('<').trim())
            .cast<String>(),
        BinOp.new);
    builder.group().left(string('and').trim().cast<String>(), BinOp.new);
    builder.group().left(string('or').trim().cast<String>(), BinOp.new);

    return builder.build();
  }

  @override
  Parser intLiteral() =>
      super.intLiteral().map((value) => IntLiteral(int.parse(value)));

  @override
  Parser stringLiteral() =>
      super.stringLiteral().map((value) => StringLiteral(value));

  @override
  Parser trueLiteral() => super.trueLiteral().map((value) => TrueLiteral());

  @override
  Parser falseLiteral() => super.falseLiteral().map((value) => FalseLiteral());

  @override
  Parser name() => super.name().map((value) => Name(value));

  @override
  Parser chunk() => super.chunk().map((value) =>
      Block((value[0] as List<dynamic>).cast<Statement>(), value[1]));

  @override
  Parser block() => super.block();

  @override
  Parser returnStatement() =>
      super.returnStatement().map((value) => ReturnStatement(value[1]));

  @override
  Parser assignment() => super.assignment().map((value) => Assignment(
        value[1],
        value[3],
        isLocal: value[0] != null,
      ));

  @override
  Parser listLiteral() =>
      super.listLiteral().castList<Field>().map((value) => TableLiteral(value));

  @override
  Parser field() => super.field().map((list) {
        var key = list[0]?[0];
        final value = list[1];
        if (key is Name) {
          key = StringLiteral(key.value);
        }
        return Field(key, value);
      });

  @override
  Parser varRef() => super.varRef().map((list) {
        var name = list[0];
        final suffixes = list[1] as List<dynamic>;
        return suffixes.fold(name, (exp, suffix) => Index(exp, suffix));
      });

  @override
  Parser ifStatement() => super.ifStatement().map((value) => IfStatement(
        value[2],
        value[4],
        value[5] == null ? null : value[5][1],
      ));
}
