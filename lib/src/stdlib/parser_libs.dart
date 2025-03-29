import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/compiler/ast_converter.dart';
import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';
import 'package:slang/src/vm/vm_extension.dart';
import 'package:uuid/uuid.dart';

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
    "expr": _expression,
    "stat": _statement,
    "block": _block,
    "uniq_id": _uniqId,
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
    "starLazy": _starLazy,
    "starSeperated": _starSeparated,
    "plus": _plus,
    "optional": _optional,
    "pick": _pick,
    "map": _map,
    "flatten": _flatten,
    "end": _end,
    "trim": _trim,
  };

  /// Returns the library itself as a slang table from the given vm
  static void _self(SlangVm vm) {
    vm.getGlobal("require");
    vm.push("slang/parser");
    vm.call(0);
    vm.run();
  }

  static void _setParserMetatable(SlangVm vm) {
    // set parser meta table
    vm.pushStack(-1);
    vm.getGlobal("__parser_meta");
    vm.setMetaTable();
  }

  /// Creates a parser that matches a string
  static bool _string(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    // push parser as userdata
    vm.push(string(str));
    // set parser meta table
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches a token
  static bool _token(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref1(vmparser.token, str));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches a keyword
  static bool _keyword(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.keywords.add(str);
    vm.push(ref1(vmparser.token, str));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches a character
  static bool _char(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    vm.push(char(str));
    _setParserMetatable(vm);
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
    _setParserMetatable(vm);
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
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches a pattern
  static bool _pattern(SlangVm vm) {
    final str = vm.getStringArg(0, name: "str");
    vm.push(pattern(str));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a reference to a parser that is created later by
  /// calling the given function
  static bool _ref(SlangVm vm) {
    final func = vm.toAny(0) as Closure;
    final args = [];
    for (var i = 1; i < vm.getTop(); i++) {
      args.add(vm.toAny(i));
    }
    dartFunc(vm, args) {
      vm.push(func);
      for (var arg in args) {
        vm.push(arg);
      }
      vm.call(args.length);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return val;
    }

    vm.push(ref(dartFunc, vm, args));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches any character
  static bool _any(SlangVm vm) {
    vm.push(any());
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches one or more of the given parser
  static bool _plus(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.plus());
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches zero or more of the given parser
  static bool _star(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.star());
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches zero or more of the given parser
  static bool _starLazy(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final limit = vm.getUserdataArg<Parser>(1, name: "limit");
    vm.push(parser.starLazy(limit));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches zero or more of the given parser
  /// seperated by the given parser
  static bool _starSeparated(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final seperator = vm.getUserdataArg<Parser>(1, name: "seperator");
    vm.push(parser.starSeparated(seperator));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that matches zero or one of the given parser
  static bool _optional(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    vm.push(parser.optional());
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that returns one value from the result of the given parser which returns a list
  static bool _pick(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");

    vm.push(parser.cast<List>().pick(vm.getIntArg(1, name: "index")));
    _setParserMetatable(vm);
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
      vm.push(result.message);
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
      // vm.push(arg);
      switch (arg) {
        case List list:
          vm.push(SlangTable.fromList(list));
        default:
          vm.push(arg);
      }
      vm.call(1);
      vm.run();
      final val = vm.toAny(-1);
      vm.pop();
      return val;
    }

    vm.push(parser.map(dartFunc));
    _setParserMetatable(vm);
    return true;
  }

  /// Creates a parser that flattens the result of the given parser
  /// into a single string
  static bool _flatten(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser<List>>(0, name: "parser");
    vm.push(parser.flatten());
    _setParserMetatable(vm);
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
    _setParserMetatable(vm);
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
    _setParserMetatable(vm);
    return true;
  }

  /// Adds a statement to the parser
  static bool _addStatement(SlangVm vm) {
    final parser = vm.getUserdataArg<Parser>(0, name: "parser");
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vmparser.addStatement(parser.map(decodeAst<Statement>));
    return false;
  }

  /// Returns a reference to the slang expression parser
  static bool _expression(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.expr).cast<AstNode>().map(astToTable));
    SlangParserLib._setParserMetatable(vm);
    return true;
  }

  /// Returns a reference to the slang statement parser
  static bool _statement(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.statement).cast<AstNode>().map(astToTable));
    SlangParserLib._setParserMetatable(vm);
    return true;
  }

  /// Returns a reference to the slang block parser
  static bool _block(SlangVm vm) {
    final vmi = vm as SlangVmImpl;
    final vmparser = vmi.compiler.extensibleParser;
    vm.push(ref0(vmparser.block).cast<AstNode>().map(astToTable));
    SlangParserLib._setParserMetatable(vm);
    return true;
  }

  /// Returns a guaranteed unique identifier
  static bool _uniqId(SlangVm vm) {
    final uuid = Uuid().v4().toString();
    vm.push(SlangTable.fromMap({"type": "Identifier", "value": "uuid-$uuid"}));
    return true;
  }

  /// Registers the parser library in the given vm
  static void register(SlangVm vm) {
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

    vm.newTable();
    vm.newTable(0, 0);
    for (var entry in _sharedFunctions.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    for (var entry in _parserMethods.entries) {
      vm.pushDartFunction(entry.value);
      vm.setField(-2, entry.key);
    }
    vm.setField(-2, "__index");
    vm.setGlobal("__parser_meta");
  }
}
