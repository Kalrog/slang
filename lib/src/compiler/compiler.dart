import 'package:petitparser/debug.dart' as debug;
import 'package:petitparser/petitparser.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/codegen/slang_code_generator.dart';
import 'package:slang/src/compiler/parser/slang_extensible_parser.dart';
import 'package:slang/src/slang_vm.dart';
import 'package:slang/src/vm/function_prototype.dart';

class SlangCompiler {
  final SlangVm vm;
  final SlangCodeGenerator generator = SlangCodeGenerator();

  SlangCompiler(this.vm);

  late final SlangExtensibleParser extensibleParser = SlangExtensibleParser(vm);
  late Parser _basicParser = extensibleParser.build();
  late Parser _traceParser =
      debug.trace(_basicParser, predicate: (parser) => parser is LabeledParser);
  late Parser parser = AlwaysSettableParser(_basicParser);

  bool _trace = false;
  bool get trace => _trace;
  set trace(bool value) {
    _trace = value;
    if (value) {
      parser = AlwaysSettableParser(_traceParser);
    } else {
      parser = AlwaysSettableParser(_basicParser);
    }
  }

  FunctionPrototype compileSource(String source, String origin) {
    final result = parser.parse(source);
    if (result is Success) {
      final ast = result.value;
      // ast.prettyPrint();
      final func = generator.generate(ast, origin);
      // print(func);
      return func;
    } else {
      throw Exception(
          'Failed to parse source: ${result.message}:$origin:${result.toPositionString()}');
    }
  }

  FunctionPrototype compileREPL(String source) {
    final statement = parser;
    final result = statement.parse(source);
    if (result is Success) {
      final ast = result.value;
      final generator = SlangCodeGenerator();
      final func = generator.generate(ast, 'repl');
      return func;
    } else {
      // throw Exception('Failed to parse source: ${result.message}:${result.position}');
      final expression = extensibleParser.buildFrom(extensibleParser.expr());
      final result = expression.parse(source);
      if (result is Success) {
        final ast = result.value as Exp;
        final statementAst = ReturnStatement(ast.token, ast);
        final generator = SlangCodeGenerator();
        final func = generator.generate(statementAst, 'repl');
        return func;
      } else {
        throw Exception('Failed to parse source: ${result.message}:${result.position}');
      }
    }
  }
}
