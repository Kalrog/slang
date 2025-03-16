import 'package:petitparser/debug.dart';
import 'package:petitparser/petitparser.dart';
import 'package:petitparser/reflection.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/codegen/slang_code_generator.dart';
import 'package:slang/src/vm/function_prototype.dart';

final _parser = optimize(SlangParser().build());
FunctionPrototype compileSource(String source, String origin) {
  final result = _parser.parse(source);
  if (result is Success) {
    final ast = result.value;
    // ast.prettyPrint();
    final generator = SlangCodeGenerator();
    final func = generator.generate(ast, origin);
    // print(func);
    return func;
  } else {
    throw Exception(
        'Failed to parse source: ${result.message}:$origin:${result.toPositionString()}');
  }
}

FunctionPrototype compileREPL(String source) {
  final statement = SlangParser().build();
  final result = statement.parse(source);
  if (result is Success) {
    final ast = result.value;
    final generator = SlangCodeGenerator();
    final func = generator.generate(ast, 'repl');
    return func;
  } else {
    // throw Exception('Failed to parse source: ${result.message}:${result.position}');
    final expression = SlangParser().buildFrom(SlangParser().expr());
    final result = expression.parse(source);
    if (result is Success) {
      final ast = result.value as Exp;
      final statementAst = ReturnStatement(ast.token, ast);
      final generator = SlangCodeGenerator();
      final func = generator.generate(statementAst, 'repl');
      return func;
    } else {
      throw Exception(
          'Failed to parse source: ${result.message}:${result.position}');
    }
  }
}
