import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/codegen/optimizer.dart';
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
  test("Ast Optimizer", () {
    final ast = SlangParser().build().parse("return 1 + 2 * 3").value;
    final optimizer = SlangConstantExpressionOptimizer();
    final optimized = optimizer.visit(ast, null);
    if (optimized
        case Block(
          finalStatement: ReturnStatement(
            exp: IntLiteral(
              value: 7,
            ),
          )
        )) {
    } else {
      throw Exception(
          "Expected optimized ast to be 'return 7', but got $optimized");
    }
  });
}
