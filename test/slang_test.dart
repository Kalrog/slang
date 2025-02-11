import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';
import 'package:test/test.dart';

class AstMatcher extends Matcher {
  final AstNode expected;

  AstMatcher(this.expected);

  @override
  Description describe(Description description) {
    return description.add('Matches AST');
  }

  @override
  bool matches(dynamic item, Map matchState) {
    if (item is Result) {
      item = item.value;
    }
    if (item is! AstNode) {
      return false;
    }
    return item.toString() == expected.toString();
  }
}

Matcher matchesAst(AstNode expected) => AstMatcher(expected);

void main() {
  test('Int Literal', () {
    final parser = SlangParser().build();
    final result = parser.parse('42');
    expect(result is Success, isTrue);
    expect(result.value, isA<IntLiteral>());
    expect((result.value as IntLiteral).value, 42);
  });

  test('Int Literal using matchesAst', () {
    final parser = SlangParser().build();
    final result = parser.parse('42');
    expect(result, matchesAst(IntLiteral(42)));
  });

  test('Unary Minus', () {
    final parser = SlangParser().build();
    final result = parser.parse('-42');
    expect(result is Success, isTrue);
    expect(result.value, isA<UnOp>());
    final unOp = result.value as UnOp;
    expect(unOp.op, '-');
    expect(unOp.exp, isA<IntLiteral>());
    expect((unOp.exp as IntLiteral).value, 42);
  });

  test('Unary Minus using matchesAst', () {
    final parser = SlangParser().build();
    final result = parser.parse('-42');
    expect(result, matchesAst(UnOp('-', IntLiteral(42))));
  });

  test('Binary Op', () {
    final parser = SlangParser().build();
    final result = parser.parse('1 + 2');
    expect(result is Success, isTrue);
    expect(result.value, isA<BinOp>());
    final binOp = result.value as BinOp;
    expect(binOp.op, '+');
    expect(binOp.left, isA<IntLiteral>());
    expect((binOp.left as IntLiteral).value, 1);
    expect(binOp.right, isA<IntLiteral>());
    expect((binOp.right as IntLiteral).value, 2);
  });

  test('Binary Op using matchesAst', () {
    final parser = SlangParser().build();
    final result = parser.parse('1 + 2');
    expect(
        result,
        matchesAst(BinOp(
          IntLiteral(1),
          '+',
          IntLiteral(2),
        )));
  });

  test('Precedence', () {
    final parser = SlangParser().build();
    final result = parser.parse('1 + 2 * 3');
    expect(result is Success, isTrue);
    expect(result.value, isA<BinOp>());
    final binOp = result.value as BinOp;
    expect(binOp.op, '+');
    expect(binOp.left, isA<IntLiteral>());
    expect((binOp.left as IntLiteral).value, 1);
    expect(binOp.right, isA<BinOp>());
    final right = binOp.right as BinOp;
    expect(right.op, '*');
    expect(right.left, isA<IntLiteral>());
    expect((right.left as IntLiteral).value, 2);
    expect(right.right, isA<IntLiteral>());
    expect((right.right as IntLiteral).value, 3);
  });

  test('Precedence using matchesAst', () {
    final parser = SlangParser().build();
    final result = parser.parse('1 + 2 * 3');
    expect(
        result,
        matchesAst(BinOp(
          IntLiteral(1),
          '+',
          BinOp(
            IntLiteral(2),
            '*',
            IntLiteral(3),
          ),
        )));
  });
}
