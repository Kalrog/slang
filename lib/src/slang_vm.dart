import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:slang/src/table.dart';
import 'package:slang/src/vm/slang_vm.dart';

import 'stdlib/libs.dart';

enum BinOpType { add, sub, mul, div, mod }

enum DebugMode { run, step, runDebug }

enum RelOpType {
  lt,
  leq,
  eq,
}

enum ThreadState { init, running, suspended, dead }

enum UnOpType { neg, not }

typedef DartFunction = bool Function(SlangVm vm);

abstract class SlangVm {
  static SlangVm create({bool loadStdLib = true}) {
    final vm = SlangVmImpl();
    if (loadStdLib) {
      SlangPackageLib.register(vm);
      SlangVmLib.register(vm);
      SlangTableLib.register(vm);
      SlangStdLib.register(vm);
      SlangStringLib.register(vm);
      SlangTestLib.register(vm);
      SlangThreadsLib.register(vm);
      SlangMathLib.register(vm);
    }
    return vm;
  }

  List<String> get args;
  set args(List<String> args);

  Stdout get stdout;
  Stdin get stdin;

  ThreadState get state;

  void addPc(int n);

  void appendTable();

  String buildStackTrace();

  void call(int nargs, {DartFunction? then});

  void run();

  bool checkDouble(int n);

  bool checkFunction(int n);

  bool checkInt(int n);

  bool checkNull(int n);

  bool checkString(int n);

  bool checkUserdata<T>(int n);

  bool checkTable(int n);

  bool checkThread(int n);

  void closeUpvalues(int fromIndex);

  void compile(dynamic code, {bool repl = false, String origin = "string"});

  Uint8List functionToBytes();

  void createThread();

  SlangVmDebug get debug;

  void endAtomic();

  void error(String message);

  void execBinOp(BinOpType op);

  void execRelOp(RelOpType op);

  void execUnOp(UnOpType op);

  bool getBoolArg(int n, {String? name, bool? defaultValue});

  double getDoubleArg(int n, {String? name, double? defaultValue});

  void getGlobal(Object identifier);

  int getIntArg(int n, {String? name, int? defaultValue});

  num getNumArg(int n, {String? name, num? defaultValue});

  String getStringArg(int n, {String? name, String? defaultValue});

  T getUserdataArg<T>(int n, {String? name, T? defaultValue});

  void getTable();

  void getTableRaw();

  void getMetaTable();

  int getTop();

  void getUpvalue(int index);

  SlangTable get globals;

  int get id;

  void jump(int n);

  void loadClosure(int index);

  void loadConstant(int index);

  void newTable([int nArray = 0, int nHash = 0]);

  void pCall(int nargs, {DartFunction? then});

  void parallel(int nargs);

  void pop([int keep = 0, int pop = 1]);

  void push(value);

  void pushDartFunction(DartFunction function);

  void pushStack(int index);

  void registerDartFunction(String name, DartFunction function);

  void replace(int index);

  bool resume(int nargs);

  void returnOp(int n);

  void setGlobal(Object identifier);

  void setTable();

  void setTableRaw();

  void setMetaTable();

  void setUpvalue(int index);

  void startAtomic();

  Object? toAny(int n);

  bool toBool(int n);

  double toDouble(int n);

  int toInt(int n);

  String toString2(int n);

  SlangVm toThread(int n);

  void type();

  void yield();
}

abstract class SlangVmDebug {
  DebugMode get mode;
  set mode(DebugMode mode);

  void debugPrint();

  void printAllStackFrames();

  void printConstants();

  void printInstructions();

  void printOpenUpvalues();

  void printStack();

  void printUpvalues();
}
