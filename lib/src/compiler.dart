import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/codegen/slang_code_generator.dart';
import 'package:slang/src/vm/function_prototype.dart';

FunctionPrototype compileSource(String source) {
  final parser = SlangParser().build();
  final result = parser.parse(source);
  if (result is Success) {
    final ast = result.value;
    ast.prettyPrint();
    final generator = SlangCodeGenerator();
    final func = generator.generate(ast);
    print(func);
    return func;
  } else {
    throw Exception('Failed to parse source: ${result.message}:${result.position}');
  }
}
