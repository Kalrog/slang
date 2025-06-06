import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/ast_converter.dart';
import 'package:slang/src/compiler/parser/slang_parser.dart';
import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/util/convension.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';
import 'package:slang/src/vm/vm_extension.dart';
import 'package:uuid/uuid.dart';

Never _throwUnsupported() => throw UnsupportedError('Unsupported operation on parser reference');

class SlangReferenceParser<R> extends Parser<R> implements ResolvableParser<R> {
  SlangReferenceParser(this.vm, this.closure, this.arguments);

  final SlangVm vm;
  final Closure closure;
  final List<dynamic> arguments;

  @override
  Parser<R> resolve() {
    vm.push(closure);
    for (var arg in arguments) {
      vm.push(arg);
    }
    vm.call(arguments.length);
    vm.run();
    final val = vm.toUserdata<Parser>(-1);
    vm.pop();
    return val as Parser<R>;
  }

  @override
  Result<R> parseOn(Context context) => _throwUnsupported();

  @override
  SlangReferenceParser<R> copy() => _throwUnsupported();

  @override
  bool operator ==(Object other) {
    if (other is SlangReferenceParser) {
      if (closure != other.closure || arguments.length != other.arguments.length) {
        return false;
      }
      for (var i = 0; i < arguments.length; i++) {
        final a = arguments[i], b = other.arguments[i];
        if (a is Parser &&
            a is! SlangReferenceParser &&
            b is Parser &&
            b is! SlangReferenceParser) {
          // for parsers do a deep equality check
          if (!a.isEqualTo(b)) {
            return false;
          }
        } else {
          // for everything else just do standard equality
          if (a != b) {
            return false;
          }
        }
      }
      return true;
    }
    return false;
  }

  @override
  int get hashCode => closure.hashCode;
}

/// Parser library for slang
///
/// This library provides slang bindings for the petit parser library.
class SlangParserLib {
  /// Library functions
  static Map<String, DartFunction> _libraryFunctions = {
    "string": _string,
    "token": _token,
    "keyword": _keyword,
    "add_statement": _addStatement,
    "add_primitive_expression": _addPrimitiveExpression,
    "add_primitive_expression_after": _addPrimitiveExpressionAfter,
    "add_primitive_expression_before": _addPrimitiveExpressionBefore,
    "add_expression_group_after": _addExpressionGroupAfter,
    "add_expression_group_before": _addExpressionGroupBefore,
    "get_primitive_expression_names": _primitiveExpressionNames,
    "get_expression_group_names": _expressionGroupNames,
    "identifier": _identifier,
    "expr": _expression,
    "stat": _statement,
    "block": _block,
    "slang_pattern": _slangPattern,
    "table_literal": _tableLiteral,
    "uniq_id": _uniqId,
    "ast_to_string": _astToString,
    "resolve": _resolve,
  };

  /// Parser methods
  static Map<String, DartFunction> _parserMethods = {
    "parse": _parse,
  };

  /// Shared functions that can either be called through the library or as methods on the parser
  static Map<String, DartFunction> _sharedFunctions = {
    "char": _char,
    "seq": _seq,
    "choice": _choice,
    "pattern": _pattern,
    "ref": _ref,
    "any": _any,
    "star": _star,
    "star_lazy": _starLazy,
    "star_seperated": _starSeparated,
    "plus": _plus,
    "plus_seperated": _plusSeparated,
    "optional": _optional,
    "forbid": _not,
    "pick": _pick,
    "permute": _permute,
    "map": _map,
    "flatten": _flatten,
    "end": _end,
    "trim": _trim,
  };

  static Map<String, DartFunction> _expressionGroupMethods = {
    "prefix": _prefix,
    "postfix": _postfix,
    "left": _left,
    "right": _right,
  };

  static void _setMetatable(SlangVm vm, String name) {
    // set parser meta table
    vm.pushStack(-1);
    vm.getGlobal("__parser_lib_metas");
    vm.push(name);
    vm.getTable();
    vm.setMetaTable();
  }

  /// Creates a parser that matches a string
  static bool _string(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    // push parser as userdata
    vm.push(string(str));
    // set parser meta table
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches a token
  static bool _token(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref1(vmparser.token, str));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches a keyword
  static bool _keyword(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.keywords.add(str);
    vm.push(ref1(vmparser.token, str));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches a character
  static bool _char(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    vm.push(char(str));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches a sequence of parsers
  static bool _seq(SlangVm vm) {
    final parsers = <Parser>[];
    for (var i = 0; i < vm.getTop(); i++) {
      parsers.add(vm.getUserdataArg<Parser>(i, name: "parser"));
    }
    final parser = SequenceParser(parsers);
    vm.push(parser);
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches one of the given parsers
  static bool _choice(SlangVm vm) {
    final parsers = <Parser>[];
    for (var i = 0; i < vm.getTop(); i++) {
      parsers.add(vm.getUserdataArg<Parser>(i, name: "parser"));
    }
    final parser = ChoiceParser(parsers);
    vm.push(parser);
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches a pattern
  static bool _pattern(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    vm.push(pattern(str));
    _setMetatable(vm, "parser");
    return true;
  }

  // static Parser _parserFuncWrapper(SlangVm vm, Closure func, List<dynamic> args) {
  //   vm.push(func);
  //   for (var arg in args) {
  //     vm.push(arg);
  //   }
  //   vm.call(args.length);
  //   vm.run();
  //   final val = vm.toUserdata<Parser>(-1);
  //   vm.pop();
  //   return val;
  // }

  /// Creates a reference to a parser that is created later by
  /// calling the given function
  static bool _ref(SlangVm vm) {
    final func = vm.toAny(0) as Closure;
    final args = [];
    for (var i = 1; i < vm.getTop(); i++) {
      args.add(vm.toAny(i));
    }

    vm.push(SlangReferenceParser(vm, func, args));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches any character
  static bool _any(SlangVm vm) {
    vm.push(any());
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches one or more of the given parser
  static bool _plus(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.plus());
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches zero or more of the given parser
  static bool _star(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.star());
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches zero or more of the given parser
  static bool _starLazy(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final limit = vm.getUserdataArg<Parser>(1, name: "limit");
    vm.push(parser.starLazy(limit));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches zero or more of the given parser
  /// seperated by the given parser
  static bool _starSeparated(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final seperator = vm.getUserdataArg<Parser>(1, name: "seperator");
    vm.push(parser.starSeparated(seperator).map((value) => SlangTable.fromMap(
        {"separators": toSlang(value.separators), "elements": toSlang(value.elements)})));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches one or more of the given parser
  /// seperated by the given parser
  static bool _plusSeparated(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final seperator = vm.getUserdataArg<Parser>(1, name: "seperator");
    vm.push(parser.plusSeparated(seperator).map((value) => SlangTable.fromMap(
        {"separators": toSlang(value.separators), "elements": toSlang(value.elements)})));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches zero or one of the given parser
  static bool _optional(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.optional());
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches the negation of the given parser
  static bool _not(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.not());
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that returns one value from the result of the given parser which returns a list
  static bool _pick(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");

    vm.push(parser.cast<List>().pick(vm.getIntArg(1, name: "index")));
    _setMetatable(vm, "parser");
    return true;
  }

  static bool _permute(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final indices = <int>[];
    for (var i = 1; i < vm.getTop(); i++) {
      indices.add(vm.getIntArg(i, name: "index"));
    }
    vm.push(parser.cast<List>().permute(indices));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Parses the given input with the given parser
  static bool _parse(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final input = vm.getStringArg(1, name: "input");
    final result = parser.parse(input);
    vm.newTable();
    if (result is Success) {
      vm.push("ok");
      vm.setField(-2, 0);
      final value = result.value;
      switch (value) {
        case AstNode node:
          final table = AstToSlangTable().visit(node);
          vm.push(table);
          vm.setField(-2, 1);
        case List list:
          vm.push(SlangTable.fromList(list));
          vm.setField(-2, 1);
        case Map<Object, Object?> map:
          vm.push(SlangTable.fromMap(map));
          vm.setField(-2, 1);
        default:
          vm.push(value);
          vm.setField(-2, 1);
      }
    } else {
      vm.push("error");
      vm.setField(-2, 0);
      vm.push("${result.message} at ${result.toPositionString()}");
      vm.setField(-2, 1);
    }
    return true;
  }

  /// Creates a parser that maps the result of the given parser to a new value
  static bool _map(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final func = vm.toAny(1) as Closure;
    dartFunc(arg) {
      vm.push(func);
      vm.push(arg);
      vm.call(1);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return val;
    }

    vm.push(parser.map(dartFunc));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that flattens the result of the given parser
  /// into a single string
  static bool _flatten(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.flatten());
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that matches the end of the input
  static bool _end(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser?>(0, name: "parser");
    if (parser == null) {
      vm.push(endOfInput());
    } else {
      vm.push(parser.end());
    }
    _setMetatable(vm, "parser");
    return true;
  }

  /// Creates a parser that trims the result of the given parser
  static bool _trim(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    Parser? before = null;
    Parser? after = null;
    if (vm.getTop() > 1) {
      before = vm.getUserdataArg<Parser?>(1, name: "before");
    }
    if (vm.getTop() > 2) {
      after = vm.getUserdataArg<Parser?>(2, name: "after");
    }
    vm.push(parser.trim(before, after));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Adds a statement to the parser
  static bool _addStatement(SlangVm vm) {
    final name = vm.getStringArg(0, name: "name");
    final parser = vm.getUserdataArg<Parser>(1, name: "parser");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.addStatement(name, parser.map(decodeAst<Statement>));
    return false;
  }

  /// Adds a primitive expression to the parser
  static bool _addPrimitiveExpression(SlangVm vm) {
    final name = vm.getStringArg(0, name: "name");
    final parser = vm.getUserdataArg<Parser>(1, name: "parser");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;

    vmparser.addPrimitiveExpression(
        PrimitiveExpressionLevel(name, resolve(parser.map(decodeAst<Exp>))));
    return false;
  }

  /// Adds a primitive expression to the parser after the given name
  static bool _addPrimitiveExpressionAfter(SlangVm vm) {
    final after = vm.getStringArg(0, name: "after");
    final name = vm.getStringArg(1, name: "name");
    final parser = vm.getUserdataArg<Parser>(2, name: "parser");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.addPrimitiveExpressionAfter(
        after, PrimitiveExpressionLevel(name, parser.map(decodeAst<Exp>)));
    return false;
  }

  /// Adds a primitive expression to the parser before the given name
  static bool _addPrimitiveExpressionBefore(SlangVm vm) {
    final before = vm.getStringArg(0, name: "before");
    final name = vm.getStringArg(1, name: "name");
    final parser = vm.getUserdataArg<Parser>(2, name: "parser");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.addPrimitiveExpressionBefore(
        before, PrimitiveExpressionLevel(name, parser.map(decodeAst<Exp>)));
    return false;
  }

  /// group:prefix(parser,(result,exp)->exp)
  static bool _prefix(SlangVm vm) {
    final group = vm.getUserdataArg<ExpressionGroup>(0, name: "group");
    final parser = vm.getUserdataArg<Parser>(1, name: "parser");
    final func = vm.toAny(2) as Closure;
    group.prefix(parser, (op, exp) {
      vm.push(func);
      vm.push(op);
      vm.push(astToTable(exp));
      vm.call(2);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return decodeAst(val);
    });
    return false;
  }

  /// group:postfix(parser,(result,exp)->exp)
  static bool _postfix(SlangVm vm) {
    final group = vm.getUserdataArg<ExpressionGroup>(0, name: "group");
    final parser = vm.getUserdataArg<Parser>(1, name: "parser");
    final func = vm.toAny(2) as Closure;
    group.postfix(parser, (exp, op) {
      vm.push(func);
      vm.push(astToTable(exp));
      vm.push(op);
      vm.call(2);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return decodeAst<Exp>(val);
    });
    return false;
  }

  /// group:left(parser,(exp,result,exp)->exp)
  static bool _left(SlangVm vm) {
    final group = vm.getUserdataArg<ExpressionGroup>(0, name: "group");
    final parser = vm.getUserdataArg<Parser>(1, name: "parser");
    final func = vm.toAny(2) as Closure;
    group.left(parser, (left, op, right) {
      vm.push(func);
      vm.push(astToTable(left));
      vm.push(op);
      vm.push(astToTable(right));
      vm.call(3);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return decodeAst<Exp>(val);
    });
    return false;
  }

  /// group:right(parser,(exp,result,exp)->exp)
  static bool _right(SlangVm vm) {
    final group = vm.getUserdataArg<ExpressionGroup>(0, name: "group");
    final parser = vm.getUserdataArg<Parser>(1, name: "parser");
    final func = vm.toAny(2) as Closure;
    group.right(parser, (right, op, left) {
      vm.push(func);
      vm.push(astToTable(right));
      vm.push(op);
      vm.push(astToTable(left));
      vm.call(3);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return decodeAst<Exp>(val);
    });
    return false;
  }

  /// Adds an expression group to the parser
  /// add_expression_group_after(after,name,(group)->group)
  static bool _addExpressionGroupAfter(SlangVm vm) {
    final after = vm.getStringArg(0, name: "after");
    final name = vm.getStringArg(1, name: "name");
    final func = vm.toAny(2) as Closure;
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.addExpressionGroupAfter(
        after,
        ExpressionGroupLevel(name, (builder) {
          final group = builder.group();
          vm.push(func);
          vm.push(group);
          _setMetatable(vm, "group");
          vm.call(1);
          vm.run();
          final val = vm.toUserdata<ExpressionGroup>(-1);
          vm.pop();
          return val;
        }));
    return false;
  }

  /// Adds an expression group to the parser
  /// add_expression_group_before(before,name,(group)->group)
  static bool _addExpressionGroupBefore(SlangVm vm) {
    final before = vm.getStringArg(0, name: "before");
    final name = vm.getStringArg(1, name: "name");
    final func = vm.toAny(2) as Closure;
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.addExpressionGroupBefore(
        before,
        ExpressionGroupLevel(name, (builder) {
          final group = builder.group();
          vm.push(func);
          vm.push(group);
          _setMetatable(vm, "group");
          vm.call(1);
          vm.run();
          final val = vm.toUserdata<ExpressionGroup>(-1);
          vm.pop();
          return val;
        }));
    return false;
  }

  static bool _primitiveExpressionNames(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(vmparser.primitiveExpressionNames);
    return true;
  }

  static bool _expressionGroupNames(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(vmparser.expressionGroupNames);
    return true;
  }

  /// Returns a reference to the slang identifier parser
  static bool _identifier(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.identifier).cast<AstNode>().map(astToTable));
    SlangParserLib._setMetatable(vm, "parser");
    return true;
  }

  /// Returns a reference to the slang expression parser
  static bool _expression(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.expr).cast<AstNode>().map(astToTable));
    SlangParserLib._setMetatable(vm, "parser");
    return true;
  }

  /// Returns a reference to the slang statement parser
  static bool _statement(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.statement).cast<AstNode>().map(astToTable));
    SlangParserLib._setMetatable(vm, "parser");
    return true;
  }

  /// Returns a reference to the slang block parser
  static bool _block(SlangVm vm) {
    final brackets = vm.getBoolArg(0, name: "brackets", defaultValue: true);
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    if (brackets) {
      vm.push(ref0(vmparser.block).cast<AstNode>().map(astToTable));
    } else {
      vm.push(ref0(vmparser.chunk).cast<AstNode>().map(astToTable));
    }
    SlangParserLib._setMetatable(vm, "parser");
    return true;
  }

  /// Returns a reference to the slang pattern parser
  static bool _slangPattern(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.slangPattern).cast<AstNode>().map(astToTable));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Returns a reference to the slang table literal parser
  static bool _tableLiteral(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.tableLiteral).cast<AstNode>().map(astToTable));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Returns a guaranteed unique identifier
  static bool _uniqId(SlangVm vm) {
    final uuid = Uuid().v4().toString();
    vm.push(SlangTable.fromMap({"type": "Identifier", "value": "uuid-$uuid"}));
    return true;
  }

  /// ast_to_string(ast)
  /// Returns a string representation of the given ast
  static bool _astToString(SlangVm vm) {
    final ast = vm.toAny(0);
    if (ast is AstNode) {
      vm.push(ast.toString());
    } else {
      vm.push(decodeAst(ast).toString());
    }
    return true;
  }

  /// resolve(parser)
  /// Resolves the given parser, any references within the parser are resolved
  static bool _resolve(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(resolve(parser));
    _setMetatable(vm, "parser");
    return true;
  }

  /// Registers the parser library in the given vm
  static void register(SlangVm vm) {
    preloadLib(vm);
    setupMetatable(vm);
  }

  static void setupMetatable(SlangVm vm) {
    vm.newTable();
    vm.newTable();
    vm.newTable();
    for (var entry in _sharedFunctions.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    for (var entry in _parserMethods.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    vm.setField(-2, "__index");
    vm.setField(-2, "parser");
    vm.newTable();
    vm.newTable();
    for (var entry in _expressionGroupMethods.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    vm.setField(-2, "__index");
    vm.setField(-2, "group");
    vm.setGlobal("__parser_lib_metas");
  }

  static void preloadLib(SlangVm vm) {
    vm.newTable(0, 0);
    for (var entry in _sharedFunctions.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    for (var entry in _libraryFunctions.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    SlangPackageLib.preloadModuleValue(vm, "slang/parser");
  }
}
