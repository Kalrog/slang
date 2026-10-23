// Stage-0 bootstrap compiler: compiles .slang sources with the Dart
// implementation and writes .slb v2 bytecode for the Go VM.
//
//   dart run tool/stage0.dart [--out DIR] [--strip PREFIX] [--prefix P] files...
//
// The module origin of each file is its path minus --strip and the .slang
// extension, with --prefix prepended. The output is DIR/<origin>.slb.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:petitparser/petitparser.dart';
import 'package:slang/slang.dart';
import 'package:slang/src/compiler/ast.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_vm.dart';

void main(List<String> argv) {
  var out = '.';
  var strip = '';
  var prefix = '';
  var dumpAst = false;
  final files = <String>[];
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--out':
        out = argv[++i];
      case '--strip':
        strip = argv[++i];
      case '--prefix':
        prefix = argv[++i];
      case '--ast':
        dumpAst = true;
      default:
        files.add(argv[i]);
    }
  }
  if (dumpAst) {
    // print the parsed (and constant-folded) AST of each file, one per line
    for (final path in files) {
      final vm = SlangVm.create() as SlangVmImpl;
      final source = File(path).readAsStringSync();
      final result = vm.compiler.parser.parse(source);
      if (result is Success) {
        print((result.value as AstNode).toString());
      } else {
        print('PARSE ERROR: ${result.message} at ${result.toPositionString()}');
      }
    }
    return;
  }
  var failed = false;
  for (final path in files) {
    var origin = path;
    if (strip.isNotEmpty && origin.startsWith(strip)) {
      origin = origin.substring(strip.length);
    }
    if (origin.endsWith('.slang')) {
      origin = origin.substring(0, origin.length - 6);
    }
    origin = prefix + origin;
    try {
      final vm = SlangVm.create();
      final source = File(path).readAsStringSync();
      vm.load(source, origin: origin);
      final closure = vm.toAny(-1) as Closure;
      final bytes = _Encoder().encode(closure.prototype!);
      final outFile = File('$out/$origin.slb');
      outFile.createSync(recursive: true);
      outFile.writeAsBytesSync(bytes);
      stderr.writeln('stage0: $path -> ${outFile.path}');
    } catch (e) {
      stderr.writeln('stage0: FAILED $path: $e');
      failed = true;
    }
  }
  if (failed) exit(1);
}

class _Encoder {
  final BytesBuilder _b = BytesBuilder();

  Uint8List encode(FunctionPrototype p) {
    _b.add(ascii.encode('SLANG'));
    _u8(2);
    _proto(p);
    return _b.toBytes();
  }

  void _u8(int v) => _b.addByte(v & 0xff);

  void _u32(int v) {
    final d = ByteData(4)..setUint32(0, v & 0xffffffff, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void _i64(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void _f64(double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.little);
    _b.add(d.buffer.asUint8List());
  }

  void _str(String s) {
    final e = utf8.encode(s);
    _u32(e.length);
    _b.add(e);
  }

  void _proto(FunctionPrototype p) {
    _u32(p.maxVarStackSize);
    _u32(p.nargs);
    _u8(p.isVarArg ? 1 : 0);
    _u32(p.instructions.length);
    for (final i in p.instructions) {
      _u32(i);
    }
    _u32(p.sourceLocations.length);
    for (final sl in p.sourceLocations) {
      _u32(sl.firstInstruction);
      _str(sl.location.origin);
      _u32(sl.location.line);
      _u32(sl.location.column);
    }
    _u32(p.constants.length);
    for (final c in p.constants) {
      switch (c) {
        case int i:
          _u8(0);
          _i64(i);
        case double d:
          _u8(1);
          _f64(d);
        case String s:
          _u8(2);
          _str(s);
        case bool b:
          _u8(3);
          _u8(b ? 1 : 0);
        case null:
          _u8(4);
        default:
          throw ArgumentError('Unsupported constant type: ${c.runtimeType}');
      }
    }
    _u32(p.upvalues.length);
    for (final u in p.upvalues) {
      _str(u.name);
      _u32(u.index);
      _u8(u.isLocal ? 1 : 0);
    }
    _u32(p.children.length);
    for (final c in p.children) {
      _proto(c);
    }
  }
}
