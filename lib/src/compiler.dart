import 'package:petitparser/debug.dart';
import 'package:petitparser/petitparser.dart';
import 'package:petitparser/reflection.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/codegen/slang_code_generator.dart';
import 'package:slang/src/vm/function_prototype.dart';

FunctionPrototype compileSource(String source) {
  var parser = SlangParser().build();
  parser = optimize(parser);
  final result = parser.parse(source);
  if (result is Success) {
    final ast = result.value;
    // ast.prettyPrint();
    final generator = SlangCodeGenerator();
    final func = generator.generate(ast);
    // print(func);
    return func;
  } else {
    throw Exception(
        'Failed to parse source: ${result.message}:${result.toPositionString()}');
  }
}

FunctionPrototype compileREPL(String source) {
  final statement = SlangParser().build();
  final result = statement.parse(source);
  if (result is Success) {
    final ast = result.value;
    final generator = SlangCodeGenerator();
    final func = generator.generate(ast);
    return func;
  } else {
    // throw Exception('Failed to parse source: ${result.message}:${result.position}');
    final expression = SlangParser().buildFrom(SlangParser().expr());
    final result = expression.parse(source);
    if (result is Success) {
      final ast = result.value as Exp;
      final statementAst = ReturnStatement(ast.token, ast);
      final generator = SlangCodeGenerator();
      final func = generator.generate(statementAst);
      return func;
    } else {
      throw Exception(
          'Failed to parse source: ${result.message}:${result.position}');
    }
  }
}
