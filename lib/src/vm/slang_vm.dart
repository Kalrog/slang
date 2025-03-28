import 'dart:io' as io;
import 'dart:math';
import 'dart:typed_data';

import 'package:slang/src/compiler/codegen/function_assembler.dart';
import 'package:slang/src/compiler/compiler.dart';
import 'package:slang/src/slang_vm.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_exception.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';
import 'package:slang/src/vm/userdata.dart';

part 'slang_vm_debug.dart';
part 'slang_vm_instructions.dart';

/// The [SlangStackFrame] is reponsible for holding the stack of the slang vm for the execution of a single
/// function.
/// It holds a stack of values and a reference to the previous stack frame.
/// Depending of if the executed [closure] is a slang function or dart function, the following other fields
/// are used by the slang vm.
/// Slang:
/// - Program Counter: The index of the current instruction in the function
/// - Open Upvalues: A map of open upvalues that are captured by closures created within the function
/// Dart:
/// - Continuation: A function that is called to continue execution of the dart function, after the slang vm
/// has finished executing a function called by the dart function.
class SlangStackFrame {
  int _pc = 0;

  /// The actual stack memory of this stack frame
  late List stack = [];

  /// The stack frame of the function that called this function
  SlangStackFrame? parent;

  /// The closure that is being executed in this stack frame
  /// or null if this is the root stack frame
  Closure? closure;

  /// The continuation function (for dart functions) that is called after the slang vm has finished executing a function
  /// called by the dart function
  DartFunction? continuation;

  /// A map of open upvalues that are captured by closures created within the function
  /// The [UpvalueHolder]s reference values in this stack frame and can only stay open as long as
  /// this stack frame exists. Then they are migrated.
  /// When this function returns, the vm will close over all open upvalues and migrate the values
  /// to be stored inside the [UpvalueHolder]s instead of on this stack frame.
  Map<int, UpvalueHolder> openUpvalues = {};

  /// A function that is called when an exception is thrown in the Slang VM
  /// The function is called with the exception and the stack trace and should return true if the exception
  /// was handled and the vm should continue execution or false if the exception was not handled and the vm
  /// pass the exception to the parent stack frame
  bool Function(SlangVm vm, Object exception, StackTrace stackTrace)? exceptionHandler;

  /// Creates a new stack frame, optionally with a closure to execute and a parent stack frame to
  /// return to after the closure has finished executing
  SlangStackFrame([this.closure, this.parent]);

  /// Returns the current instruction of the closure that is being executed in this stack frame
  /// or null if the closure is null or a dart function
  int? get currentInstruction => function?.instructions[_pc];

  /// Returns the current source location of the instruction that is being executed in this stack frame
  /// or null if the closure is null or a dart function
  SourceLocation? get currentInstructionLocation {
    if (function == null) {
      return null;
    }
    var index = 0;
    for (final location in function!.sourceLocations) {
      if (location.firstInstruction > pc) {
        break;
      }
      index++;
    }
    if (index >= function!.sourceLocations.length) {
      return function!.sourceLocations.last.location;
    }
    return function!.sourceLocations[index].location;
  }

  /// Returns the function prototype of the closure that is being executed in this stack frame
  /// or null if the closure is null or a dart function
  FunctionPrototype? get function => closure?.prototype;

  /// Returns the program counter of the closure that is being executed in this stack frame
  int get pc => _pc;

  /// Returns the height/top of the stack
  int get top => stack.length;

  /// Returns the value at the given index of the stack
  /// for negative indices, the index is counted from the top of the stack
  /// if the index is out of bounds, null is returned
  operator [](int index) {
    final absIdx = _absIndex(index);
    if (absIdx >= stack.length || absIdx < 0) {
      return null;
    }
    return stack[absIdx];
  }

  /// Sets the value at the given index of the stack
  /// for negative indices, the index is counted from the top of the stack
  operator []=(int index, dynamic value) {
    final absIdx = _absIndex(index);
    stack[absIdx] = value;
  }

  int _absIndex(int index) {
    if (index < 0) {
      return stack.length + index;
    }
    return index;
  }

  /// Increments the program counter by [n]
  void addPc(int n) {
    _pc += n;
  }

  /// Pops [n] values from the stack and returns them
  /// If [n] is 0, null is returned
  /// If [n] is 1, only the top value is returned
  /// If [n] is greater than 1, a list of the top [n] values is returned
  dynamic pop([int n = 1]) {
    // return stack.removeLast();
    if (n == 0) {
      return null;
    }
    if (n == 1) {
      return stack.removeLast();
    }
    final result = stack.sublist(stack.length - n);
    stack.removeRange(stack.length - n, stack.length);
    return result;
  }

  /// Pushes a value onto the stack
  /// If the stack is already at the maximum size of 5000, a stack overflow exception is thrown
  void push(dynamic value) {
    stack.add(value);
    if (stack.length > 5000) {
      throw Exception("Stack overflow");
    }
  }

  void pushAll(List values) {
    stack.addAll(values);
    if (stack.length > 5000) {
      throw Exception("Stack overflow");
    }
  }

  /// Removes all values from the stack that are above the given index
  /// If the index is greater than the current stack size, null values are added to the stack
  /// until the stack is at the given index
  void setTop(int top) {
    if (top < stack.length) {
      stack.removeRange(top, stack.length);
    } else {
      stack.addAll(List.filled(top - stack.length, null));
    }
  }

  @override
  String toString() {
    StringBuffer buffer = StringBuffer();
    for (var i = stack.length - 1; i >= 0; i--) {
      // 2  | int | 42
      // 1  | int | 12
      // 0  | int | 30
      buffer.writeln(
          '${i.toString().padLeft(3)}  | ${stack[i].runtimeType.toString().padRight(8)} | ${stack[i]}');
    }
    return buffer.toString();
  }
}

/// Implementation of the Slang VM
class SlangVmImpl implements SlangVm {
  late final SlangCompiler compiler = SlangCompiler(this);
  static int _id = 0;
  static const _threadSwitchTime = 10;
  @override
  final int id = SlangVmImpl._id++;
  SlangStackFrame _frame = SlangStackFrame();
  SlangTable _globals = SlangTable();
  @override
  late final SlangVmImplDebug debug = SlangVmImplDebug(this);

  @override
  ThreadState state = ThreadState.init;

  @override
  SlangTable get globals => _globals;

  @override
  List<String> args = [];

  bool get _inAtomicSection {
    return (globals["__thread"] as SlangTable)["atomic"] as bool;
  }

  set _inAtomicSection(bool value) {
    (globals["__thread"] as SlangTable)["atomic"] = value;
  }

  @override
  io.Stdin stdin = io.stdin;

  @override
  io.Stdout stdout = io.stdout;

  @override
  @pragma("vm:prefer-inline")
  void addPc(int n) {
    _frame.addPc(n);
  }

  @override
  void appendTable() {
    final value = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    table[table.length] = value;
  }

  @override
  String buildStackTrace() {
    final buffer = StringBuffer();
    buffer.write(_frame.toString());
    for (SlangStackFrame? frame = _frame; frame != null; frame = frame.parent) {
      final location = frame.currentInstructionLocation;
      final closureName = frame.closure?.isDart == true ? "dart closure" : "unknown closure";
      if (location != null) {
        buffer.writeln("$closureName:$location");
      } else {
        buffer.writeln("$closureName:unknown location");
      }
    }
    return buffer.toString();
  }

  @override
  void pCall(int nargs, {DartFunction? then}) {
    final currentStack = _frame;
    _frame.exceptionHandler = (vm, exception, stackTrace) {
      var err = exception;
      if (err is! SlangException) {
        err = SlangException(
            "$err ${buildStackTrace()} $stackTrace", _frame.currentInstructionLocation);
      }
      while (_frame != currentStack) {
        _popStack();
      }
      _popStack();
      newTable();
      pushStack(-1);
      push("err");
      appendTable();
      pushStack(-1);
      err.toSlang(this);
      appendTable();
      if (debug.mode == DebugMode.runDebug) {
        debug.mode = DebugMode.step;
        print(err);
      }
      return true;
    };

    call(
      nargs,
      then: (vm) {
        newTable();
        pushStack(-1);
        push("ok");
        appendTable();
        pushStack(-1);
        pushStack(-3);
        appendTable();
        pop(1, 1);
        if (then != null) {
          return then(this);
        } else {
          return true;
        }
      },
    );
  }

  @override
  void call(int nargs, {DartFunction? then}) {
    _frame.continuation = then;
    _prepareCall(nargs);
  }

  @override
  void run() {
    final parentFrame = _frame.parent;
    while (_frame != parentFrame && _frame.closure != null) {
      step();
    }
  }

  @override
  bool checkDouble(int n) {
    return _frame[n] is double;
  }

  @override
  bool checkFunction(int n) {
    return _frame[n] is Closure;
  }

  @override
  bool checkInt(int n) {
    return _frame[n] is int;
  }

  @override
  bool checkNull(int n) {
    return _frame[n] == null;
  }

  @override
  bool checkString(int n) {
    return _frame[n] is String;
  }

  @override
  bool checkUserdata<T>(int n) {
    return _frame[n] is Userdata && _frame[n].value is T;
  }

  @override
  bool checkTable(int n) {
    return _frame[n] is SlangTable;
  }

  @override
  bool checkThread(int n) {
    return _frame[n] is SlangVmImpl;
  }

  @override
  void closeUpvalues(int fromIndex) {
    _frame.openUpvalues.removeWhere((_, upvalue) {
      if (upvalue.index >= fromIndex) {
        upvalue.migrate();
        return true;
      }
      return false;
    });
  }

  @override
  void load(dynamic code, {bool repl = false, String origin = "string"}) {
    FunctionPrototype? prototype;

    if (code is Uint8List) {
      prototype = PrototypeEncoder().decode(code);
    }
    if (code is FunctionPrototype) {
      prototype = code;
    }
    if (prototype == null) {
      final codeString = code is String ? code : String.fromCharCodes(code);
      prototype =
          repl ? compiler.compileREPL(codeString) : compiler.compileSource(codeString, origin);
    }

    Closure closure = Closure.slang(prototype);

    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    _frame.push(closure);
  }

  @override
  Uint8List functionToBytes() {
    final closure = _frame.pop();
    if (closure is! Closure) {
      throw Exception('Expected Closure got $closure');
    }
    if (closure.prototype == null) {
      throw Exception('Closure has no prototype');
    }
    final bytes = PrototypeEncoder().encode(closure.prototype!);
    return bytes;
  }

  SlangVm createChild() {
    final vm = SlangVmImpl();
    vm._globals = globals;
    return vm;
  }

  @override
  void createThread() {
    final closure = _frame.pop();
    if (closure is! Closure) {
      throw Exception('Expected Closure got $closure');
    }
    final thread = createChild();
    thread.push(closure);
    push(thread);
  }

  @override
  void endAtomic() {
    if (!_inAtomicSection) {
      throw Exception("Cannot end atomic section outside atomic section");
    }
    _inAtomicSection = false;
  }

  @override
  void error(String message) {
    throw SlangException(message, _frame.parent?.currentInstructionLocation);
  }

  @override
  @pragma("vm:prefer-inline")
  void execBinOp(BinOpType op) {
    final b = _frame.pop();
    final a = _frame.pop();
    switch (op) {
      case BinOpType.add:
        _frame.push(a + b);
      case BinOpType.sub:
        _frame.push(a - b);
      case BinOpType.mul:
        _frame.push(a * b);
      case BinOpType.div:
        _frame.push(a / b);
      case BinOpType.mod:
        _frame.push(a % b);
    }
  }

  @override
  @pragma("vm:prefer-inline")
  void execRelOp(RelOpType op) {
    final b = _frame.pop();
    final a = _frame.pop();
    switch (op) {
      case RelOpType.lt:
        _frame.push(a < b);
      case RelOpType.leq:
        _frame.push(a <= b);
      case RelOpType.eq:
        _frame.push(a == b);
    }
  }

  @override
  @pragma("vm:prefer-inline")
  void execUnOp(UnOpType op) {
    final a = _frame.pop();
    switch (op) {
      case UnOpType.neg:
        _frame.push(-a);
      case UnOpType.not:
        _frame.push(!a);
    }
  }

  /// Push `global[identifier]` onto the stack
  @override
  void getGlobal(Object identifier) {
    _frame.push(globals[identifier]);
  }

  @override
  bool getBoolArg(int n, {String? name, bool? defaultValue}) {
    if (!checkInt(n)) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw Exception('Expected bool for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toBool(n);
  }

  @override
  double getDoubleArg(int n, {String? name, double? defaultValue}) {
    if (!checkDouble(n)) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw Exception('Expected double for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toDouble(n);
  }

  @override
  int getIntArg(int n, {String? name, int? defaultValue}) {
    if (!checkInt(n)) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw Exception('Expected int for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toInt(n);
  }

  @override
  num getNumArg(int n, {String? name, num? defaultValue}) {
    if (!checkDouble(n) && !checkInt(n)) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw Exception('Expected num for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return _frame[n] as num;
  }

  @override
  String getStringArg(int n, {String? name, String? defaultValue}) {
    if (!checkString(n)) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw Exception('Expected String for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toString2(n);
  }

  @override
  T getUserdataArg<T>(int n, {String? name, T? defaultValue}) {
    if (!checkUserdata<T>(n)) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw Exception(
          'Expected SlangTable for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    final table = _frame[n];
    if (table is! Userdata) {
      throw Exception('Expected Userdata for ${name ?? n.toString()} got ${table.runtimeType}');
    }
    return table.value as T;
  }

  @override
  void getTable() {
    final key = _frame.pop();
    final table = _frame.pop();
    if (table == null) {
      throw Exception('Expected SlangTable got null');
    }
    _getTable(table, key);
  }

  @override
  void getTableRaw() {
    final key = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    _frame.push(table[key]);
  }

  @override
  void getMetaTable() {
    final table = _frame.pop();
    switch (table) {
      case SlangTable(metatable: final meta):
        _frame.push(meta);
      case Userdata(metatable: final meta):
        _frame.push(meta);
      default:
        throw Exception('Expected SlangTable or Userdata got ${table.runtimeType}');
    }
  }

  @override
  int getTop() {
    return _frame.top;
  }

  @override
  void getUpvalue(int index) {
    final upvalue = _frame.closure!.upvalues[index];
    _frame.push(upvalue!.get());
  }

  @override
  void jump(int n) {
    addPc(n);
  }

  @override
  void loadClosure(int index) {
    final prototype = _frame.function!.children[index];
    Closure closure = Closure.slang(prototype);
    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    for (final (index, uv) in prototype.upvalues.indexed) {
      if (uv.isLocal && _frame.openUpvalues[uv.index] != null) {
        closure.upvalues[index] = _frame.openUpvalues[uv.index];
      } else if (uv.isLocal) {
        closure.upvalues[index] = UpvalueHolder.stack(_frame, uv.index);
        _frame.openUpvalues[uv.index] = closure.upvalues[index]!;
      } else {
        closure.upvalues[index] = _frame.closure!.upvalues[uv.index];
      }
    }
    _frame.push(closure);
  }

  @override
  void loadConstant(int index) {
    final k = _frame.function!.constants[index];
    _frame.push(k);
  }

  @override
  void newTable([int nArray = 0, int nHash = 0]) {
    _frame.push(SlangTable(nArray, nHash));
  }

  // Runs a set of slang threads using preemtive parallelization
  // all threads will be run until either all are dead or all are suspended
  @override
  void parallel(int nargs) {
    bool allSuspended(List<SlangVmImpl> threads) =>
        threads.every((t) => t.state == ThreadState.dead || t.state == ThreadState.suspended);

    final SlangTable spawned = (globals["__thread"] as SlangTable)["spawn"] as SlangTable;

    var args = _frame.pop(nargs);
    if (args is! List) {
      args = [args];
    }
    List<SlangVmImpl> threads = (args as List<Object?>).cast<SlangVmImpl>();
    threads.removeWhere((t) => t.state == ThreadState.dead);
    int current = 0;
    for (final thread in threads) {
      thread.debug.mode = debug.mode;
    }
    while (threads.isNotEmpty && !allSuspended(threads)) {
      final thread = threads[current];
      // TODO(JonathanKohlhas): Replace with set number for actually using it, but
      // great for testing, makes the point at which threads switch random
      for (int i = 0; i < Random().nextInt(20); i++) {
        if (thread.state == ThreadState.dead ||
            (thread.state == ThreadState.suspended && !_inAtomicSection)) {
          break;
        }

        try {
          if (thread.state == ThreadState.init) {
            thread.call(0);
          }
          if (thread._frame.closure == null) {
            thread.state = ThreadState.dead;
            break;
          } else {
            thread.step();
          }
        } catch (e, stack) {
          print(buildStackTrace());
          print("Error: $e");
          print("Stack: $stack");
          rethrow;
        }
      }
      if (!_inAtomicSection) {
        // remove dead threads
        threads.removeWhere((t) => t.state == ThreadState.dead);
        // add newly spawned threads
        threads.addAll(spawned.values.whereType<SlangVmImpl>());
        spawned.clear();
        if (threads.isNotEmpty) {
          current = (current + 1) % threads.length;
        }
      }
    }
  }

  @override
  void pop([int keep = 0, int pop = 1]) {
    final popped = _frame.pop(pop + keep);
    if (keep > 0) {
      final kept = popped.sublist(pop);
      _frame.stack.addAll(kept);
    }
  }

  @override
  void push(dynamic value) {
    switch (value) {
      case int() ||
            double() ||
            String() ||
            bool() ||
            Null() ||
            Closure() ||
            SlangVmImpl() ||
            Userdata() ||
            SlangTable() ||
            DartFunction():
        _frame.push(value);
      case Object any:
        _frame.push(Userdata(any));
    }
  }

  @override
  void pushDartFunction(DartFunction function) {
    push(Closure.dart(function));
  }

  @override
  @pragma("vm:prefer-inline")
  void pushStack(int index) {
    _frame.push(_frame[index]);
  }

  @override
  void registerDartFunction(String name, DartFunction function) {
    // globals[name] = Closure.dart(function);
    pushDartFunction(function);
    setGlobal(name);
  }

  @override
  @pragma("vm:prefer-inline")
  void replace(int index) {
    _frame[index] = _frame.pop();
  }

  @override
  bool resume(int nargs) {
    final List<Object?> args;
    switch (nargs) {
      case 0:
        args = [null];
      case 1:
        args = [_frame.pop(1)];
      default:
        throw Exception('Can only continue with 0 or 1 arguments');
    }
    final thread = _frame.pop();
    if (thread is! SlangVmImpl) {
      throw Exception('Expected Thread got $thread');
    }
    if (thread.state == ThreadState.dead) {
      return false;
    }
    if (thread.state == ThreadState.init) {
      for (final arg in args) {
        thread.push(arg);
      }
      thread.call(args.length);
      thread.state == ThreadState.running;
    }

    if (thread.state == ThreadState.suspended) {
      //remove the yield return value and push the actual return value
      for (final arg in args) {
        thread.push(arg);
      }
      thread.state = ThreadState.running;
    }

    //run the thread until it yields again
    bool runUntilYields(SlangVm vm) {
      final vmi = vm as SlangVmImpl;
      vmi._frame.continuation = runUntilYields;
      thread.step();
      if (thread.state == ThreadState.suspended || thread._frame.closure == null) {
        if (thread._frame.closure == null) {
          thread.state = ThreadState.dead;
        }
        vmi._frame.continuation = null;
        // take top of stack and put it on our stack
        if (thread._frame.top > 0) {
          push(thread._frame.pop());
        } else {
          push(null);
        }
        return true;
      }
      return false;
    }

    return runUntilYields(this);
  }

  @override
  void returnOp(int n) {
    final result = _frame[n];
    _popStack();
    _frame.push(result);
  }

  /// Take value from stack and set `global[identifier]`
  @override
  void setGlobal(Object identifier) {
    globals[identifier] = _frame.pop();
  }

  @override
  void setTable() {
    final value = _frame.pop();
    final key = _frame.pop();
    final table = _frame.pop();
    if (table == null) {
      throw Exception('Expected SlangTable got null');
    }
    _setTable(table, key, value);
  }

  @override
  void setTableRaw() {
    final value = _frame.pop();
    final key = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    table[key] = value;
  }

  @override
  void setMetaTable() {
    final value = _frame.pop();
    final table = _frame.pop();
    if (value is! SlangTable?) {
      throw Exception('Expected SlangTable got ${value.runtimeType}');
    }
    switch (table) {
      case SlangTable slangTable:
        slangTable.metatable = value;
      case Userdata userdata:
        userdata.metatable = value;
      default:
        throw Exception('Expected SlangTable or Userdata got ${table.runtimeType}');
    }
  }

  @override
  void setUpvalue(int index) {
    final value = _frame.pop();
    final upvalue = _frame.closure!.upvalues[index];
    upvalue!.set(value);
  }

  @override
  void startAtomic() {
    if (_inAtomicSection) {
      throw Exception("Cannot start atomic section inside atomic section");
    }
    _inAtomicSection = true;
  }

  @override
  Object? toAny(int n) {
    final value = _frame[n];
    return value;
  }

  @override
  bool toBool(int n) {
    return _frame[n] != null && _frame[n] != false;
  }

  @override
  double toDouble(int n) {
    return _frame[n] as double;
  }

  @override
  int toInt(int n) {
    return _frame[n] as int;
  }

  @override
  String toString2(int n) {
    return _frame[n].toString();
  }

  @override
  SlangVmImpl toThread(int n) {
    return _frame[n] as SlangVmImpl;
  }

  @override
  void type() {
    final value = _frame.pop();
    if (value == null) {
      _frame.push("null");
      return;
    }
    final type = _getMetafield(value, "__type");
    if (type != null) {
      _frame.push(type);
      return;
    }

    switch (value) {
      case int():
        _frame.push("int");
      case double():
        _frame.push("double");
      case String():
        _frame.push("string");
      case bool():
        _frame.push("bool");
      case Closure():
        _frame.push("function");
      case SlangVmImpl():
        _frame.push("thread");
      case Userdata():
        _frame.push("userdata");
      case SlangTable():
        _frame.push("table");
      default:
        // _frame.push("null");
        throw Exception('Cannot get type of $value');
    }
  }

  @override
  void yield() {
    state = ThreadState.suspended;
  }

  Object? _getMetafield(Object object, String field) {
    return switch (object) {
      SlangTable(metatable: final meta) => meta?[field],
      Userdata(metatable: final meta) => meta?[field],
      _ => null,
    };
  }

  Object? _getRaw(Object object, Object key) {
    if (object case SlangTable table) {
      return table[key];
    }
    return null;
  }

  void _setRaw(Object object, Object key, Object? value) {
    if (object case SlangTable table) {
      table[key] = value;
      return;
    }
    throw Exception('Cannot set value on $object');
  }

  void _getTable(Object table, Object key) {
    final value = _getRaw(table, key);
    final index = _getMetafield(table, "__index");
    if (value != null || index == null) {
      _frame.push(value);
      return;
    }
    switch (index) {
      case Closure closure:
        _frame.push(closure);
        _frame.push(table);
        _frame.push(key);
        call(2);
        run();
        return;
      case SlangTable table:
        _getTable(table, key);
        return;
      default:
        _frame.push(null);
        return;
    }
  }

  void _popStack() {
    for (final upvalue in _frame.openUpvalues.values) {
      upvalue.migrate();
    }
    _frame = _frame.parent!;
  }

  /// Prepare the call by popping the arguments and closure from the stack
  /// and pushing the arguments onto the stack of the new frame
  /// returns the closure that is being called
  Closure _prepareCall(int nargs) {
    state = ThreadState.running;
    var args = _frame.pop(nargs);
    if (nargs == 0) {
      args = [];
    }
    if (args is! List) {
      args = <Object?>[args];
    }
    final closure = _frame.pop();
    if (closure is! Closure) {
      debug.printStack();
      throw Exception('Expected Closure got $closure');
    }
    _pushStack(closure);

    if (closure.isDart) {
      _frame.continuation = closure.dartFunction;
    }

    if (closure.isSlang) {
      final proto = closure.prototype!;
      final nargs = proto.isVarArg ? proto.nargs - 1 : proto.nargs;
      final extraArgs = SlangTable();
      final normalArgs = args.sublist(0, nargs);
      // for (final (index, arg) in args.indexed) {
      //   if (index < nargs) {
      //     _frame.push(arg);
      //   } else if (proto.isVarArg) {
      //     extraArgs.add(arg);
      //   }
      // }
      if (proto.isVarArg) {
        extraArgs.addAllList(args.sublist(nargs));
        normalArgs.add(extraArgs);
      }
      _frame.pushAll(normalArgs);
    } else {
      // for (final arg in args) {
      //   // _frame.push(arg);
      // }
      _frame.pushAll(args);
    }
    if (closure.isSlang) {
      _frame.setTop(closure.prototype!.maxVarStackSize);
    }
    return closure;
  }

  void _pushStack([Closure? closure]) {
    _frame = SlangStackFrame(closure, _frame);
  }

  void _setTable(Object table, Object key, Object? value) {
    final current = _getRaw(table, key);
    final newIndex = _getMetafield(table, "__newindex");
    if (current != null || newIndex == null) {
      _setRaw(table, key, value);
      return;
    }

    switch (newIndex) {
      case Closure closure:
        _frame.push(closure);
        _frame.push(table);
        _frame.push(key);
        _frame.push(value);
        call(3);
        run();
        return;
      case SlangTable table:
        _setTable(table, key, value);
        return;
      default:
        return;
    }
  }

  void _stepSlang() {
    if (_frame.closure?.isSlang != true) {
      throw (Exception("Cannot step slang function while not inside slang function"));
    }
    final instruction = _frame.currentInstruction;
    final op = instruction!.op;
    debug._runDebugFunctionality();
    addPc(1);
    op.execute(this, instruction);
  }

  @pragma("vm:prefer-inline")
  void _stepSwitchSlang() {
    if (_frame.closure?.isSlang != true) {
      throw (Exception("Cannot step slang function while not inside slang function"));
    }
    final instruction = _frame.closure!.prototype!.instructions[_frame.pc];
    // final op = instruction!.op;
    final op = instruction.opcode;
    debug._runDebugFunctionality();
    // addPc(1);
    // _frame.addPc(1);
    _frame._pc += 1;
    // op.execute(this, instruction);
    switch (op) {
      case 0: // LOAD CONSTANT
        loadConstant(instruction.bx);
      case 1: //Load BOOL
        bool value = instruction.b != 0;
        push(value);
        if (instruction.c != 0) {
          jump(1);
        }
      case 2: //load closure
        loadClosure(instruction.ax);
      case 3: //ADD
        execBinOp(BinOpType.add);
      case 4: //SUB
        execBinOp(BinOpType.sub);
      case 5: //MUL
        execBinOp(BinOpType.mul);
      case 6: //DIV
        execBinOp(BinOpType.div);
      case 7: //MOD
        execBinOp(BinOpType.mod);
      case 8: //NEG
        execUnOp(UnOpType.neg);
      case 9: //NOT
        execUnOp(UnOpType.not);
      case 10: //EQ
        execRelOp(RelOpType.eq);
      case 11: //LT
        execRelOp(RelOpType.lt);
      case 12: //LEQ
        execRelOp(RelOpType.leq);
      case 13: //move
        replace(instruction.sbx);
      case 14: //push
        pushStack(instruction.sbx);
      case 15: //pop
        pop(instruction.a, instruction.bx);
      case 16: //return
        returnOp(-1);
      case 17: //new table
        newTable(instruction.b, instruction.c);
      case 18: //set table
        setTable();
      case 19: //get table
        getTable();
      case 20: //set upvalue
        setUpvalue(instruction.ax);
      case 21: //get upvalue
        getUpvalue(instruction.ax);
      case 22: //close upvalues
        closeUpvalues(instruction.ax);
      case 23: //test
        if (toBool(-1) != (instruction.c != 0)) {
          jump(1);
        }
        pop();
      case 24: //jump
        jump(instruction.sbx);
      case 25: //call
        call(instruction.bx);
      case 26: //type
        type();
      default:
        throw Exception("Unknown opcode $op");
    }
  }

  void _stepDart() {
    final dartFrame = _frame;
    if (_frame.closure?.isDart != true) {
      throw (Exception("Cannot step dart function while not inside dart function"));
    }
    final function = _frame.continuation;
    if (function == null) {
      throw Exception("Cannot run continuation without a continuation function");
    }
    _frame.continuation =
        null; //we are going to run this continuation now, so it is no longer needed on the stack
    var returnsValue = function(this);

    if (dartFrame.continuation == null || returnsValue == true) {
      /// no more other stuff this dart function wants to do
      /// so we can return
      assert(_frame ==
          dartFrame); // if we are done with continuations, we should be back at the same stack frame

      Object? returnValue;
      if (returnsValue) {
        returnValue = _frame.pop();
      }
      _popStack();
      _frame.push(returnValue);
    }
  }

  /// Run a single step of the slang vm
  @pragma("vm:prefer-inline")
  void step() {
    try {
      if (_frame.closure?.isSlang == true) {
        _stepSwitchSlang();
      } else if (_frame.closure?.isDart == true) {
        _stepDart();
      } else {
        throw Exception("Cannot step while not inside a function");
      }
    } catch (e, stack) {
      for (SlangStackFrame? frame = _frame; frame != null; frame = frame.parent) {
        if (frame.exceptionHandler != null) {
          if (frame.exceptionHandler!(this, e, stack)) {
            return;
          }
        }
      }
      print("Uncaught exception");
      print(buildStackTrace());
      print("Error: $e");
      print("Stack: $stack");
      rethrow;
    }
  }
}
