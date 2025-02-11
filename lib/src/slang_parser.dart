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
    builder.primitive(ref0(name).cast<Exp>());
    builder.group().wrapper(char('(').trim(), char(')').trim(), (left, value, right) => value);
    builder.group().right(char('^').trim(), BinOp.new);
    builder.group().prefix(char('-').trim(), UnOp.new);
    builder.group().left((char('*') | char('/') | char('%')).trim().cast<String>(), BinOp.new);
    builder.group().left((char('-') | char('+')).trim().cast<String>(), BinOp.new);

    return builder.build();
  }

  @override
  Parser intLiteral() => super.intLiteral().map((value) => IntLiteral(int.parse(value)));

  @override
  Parser stringLiteral() => super.stringLiteral().map((value) => StringLiteral(value));

  @override
  Parser name() => super.name().map((value) => Name(value));

  @override
  Parser block() =>
      super.block().map((value) => Block((value[0] as List<dynamic>).cast<Statement>(), value[1]));

  @override
  Parser returnStatement() => super.returnStatement().map((value) => ReturnStatement(value[1]));

  @override
  Parser assignment() => super.assignment().map((value) => Assignment(
        value[1],
        value[3],
        isLocal: value[0] != null,
      ));
}
