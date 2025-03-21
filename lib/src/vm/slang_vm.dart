import 'dart:io';
import 'dart:math';

import 'package:slang/src/compiler/codegen/function_assembler.dart';
import 'package:slang/src/compiler/compiler.dart';
import 'package:slang/src/slang_vm.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/function_prototype.dart';
import 'package:slang/src/vm/slang_exception.dart';
import 'package:slang/src/vm/slang_vm_bytecode.dart';

part 'slang_vm_debug.dart';
part 'slang_vm_instructions.dart';

/// The slang vm is a stack based virtual machine that executes slang bytecode
/// It can operate in two modes:
/// 1. Dart stack mode: When a slang function is called, a stackframe is created and the slang function
/// instructions are loaded, then a dart function called _runSlangFunction is called that will execute
/// each step of the slang function until it is completed.
/// When the slang function returns, the dart function will also return.
/// In this mode, preemtive parallelization is not possible, because to do so the slang vm would
/// have to preemtively switch out of the _runSlangFunction function, which is not possible.
/// 2. Step mode: When a slang function is called, a stackframe is created and the slang function
/// instructions are loaded, but nothing else is done. To execute actually the function, repeated calls
/// to the _step function must be made until the slang function is completed.
/// This allows for preemtive parallelization, because it is possible to switch between calling _step
/// on different SlangVm instances.
enum ExecutionMode {
  /// Execution of slang code will create an equivalent dart stack
  /// each call to a slang function will result in a call to a dart function
  /// to execute each of the instructions in the slang function
  /// In dart stack mode, preemtive parallelization is not possible, because
  /// the
  dartStack,

  /// Execution of slang code is driven by a single source, that repeatedly steps the
  /// slang vm until the slang function is completed.
  /// The call stack only exists within the slang vm.
  /// In step mode, preemtive parallelization is possible, because the source can
  /// switch between driving different threads(VMs).
  step,
}

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
  static int _id = 0;
  static const _threadSwitchTime = 10;
  @override
  final int id = SlangVmImpl._id++;
  SlangStackFrame _frame = SlangStackFrame();
  SlangTable _globals = SlangTable();
  @override
  late final SlangVmImplDebug debug = SlangVmImplDebug(this);

  /// The current execution mode of the slang vm
  /// See [ExecutionMode] for more information
  ExecutionMode executionMode = ExecutionMode.dartStack;

  @override
  ThreadState state = ThreadState.init;

  @override
  SlangTable get globals => _globals;

  bool get _inAtomicSection {
    return (globals["__thread"] as SlangTable)["atomic"] as bool;
  }

  set _inAtomicSection(bool value) {
    (globals["__thread"] as SlangTable)["atomic"] = value;
  }

  @override
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
  void call(int nargs, {DartFunction? then}) {
    _frame.continuation = then;
    bool isRoot = _frame.parent == null;
    var closure = _prepareCall(nargs);

    try {
      if (closure.prototype != null) {
        if (executionMode == ExecutionMode.dartStack) {
          _runSlangFunction();
        }
      } else {
        _runDartFunction();
      }
    } on SlangYield {
      rethrow;
    } catch (e, stack) {
      if (isRoot) {
        print(buildStackTrace());
        print("Error: $e");
        print("Stack: $stack");
      }
      rethrow;
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
  void compile(String code, {bool repl = false, String origin = "string"}) {
    final prototype = repl ? compileREPL(code) : compileSource(code, origin);
    Closure closure = Closure.slang(prototype);
    if (prototype.upvalues.isNotEmpty && prototype.upvalues[0].name == '_ENV') {
      closure.upvalues[0] = UpvalueHolder.value(globals);
    }
    _frame.push(closure);
  }

  @override
  void createThread() {
    final closure = _frame.pop();
    if (closure is! Closure) {
      throw Exception('Expected Closure got $closure');
    }
    final thread = SlangVmImpl();
    thread._globals = globals;
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
  void execUnOp(UnOpType op) {
    final a = _frame.pop();
    switch (op) {
      case UnOpType.neg:
        _frame.push(-a);
      case UnOpType.not:
        _frame.push(!a);
    }
  }

  @override
  bool getBoolArg(int n, {String? name, bool? defaultValue}) {
    if (!checkInt(n)) {
      throw Exception('Expected bool for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toBool(n);
  }

  @override
  double getDoubleArg(int n, {String? name, double? defaultValue}) {
    if (!checkDouble(n)) {
      throw Exception('Expected double for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toDouble(n);
  }

  /// Push `global[identifier]` onto the stack
  @override
  void getGlobal(Object identifier) {
    _frame.push(globals[identifier]);
  }

  @override
  int getIntArg(int n, {String? name, int? defaultValue}) {
    if (!checkInt(n)) {
      throw Exception('Expected int for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toInt(n);
  }

  @override
  num getNumArg(int n, {String? name, num? defaultValue}) {
    if (!checkDouble(n) && !checkInt(n)) {
      throw Exception('Expected num for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return _frame[n] as num;
  }

  @override
  String getStringArg(int n, {String? name, String? defaultValue}) {
    if (!checkString(n)) {
      throw Exception('Expected String for ${name ?? n.toString()} got ${_frame[n].runtimeType}');
    }
    return toString2(n);
  }

  @override
  void getTable() {
    final key = _frame.pop();
    final table = _frame.pop();
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}, $table[$key]');
    }
    _getTable(table, key);
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
    bool _allSuspended(List<SlangVmImpl> threads) =>
        threads.every((t) => t.state == ThreadState.dead || t.state == ThreadState.suspended);
    var args = _frame.pop(nargs);
    if (args is! List) {
      args = [args];
    }
    List<SlangVmImpl> threads = (args as List<Object?>).cast<SlangVmImpl>();
    final originalThreads = threads;
    threads.removeWhere((t) => t.state == ThreadState.dead);
    int current = 0;
    for (final thread in threads) {
      thread.executionMode = ExecutionMode.step;
      thread.debug.mode = debug.mode;
    }
    while (threads.isNotEmpty && !_allSuspended(threads)) {
      final thread = threads[current];
      // TODO(JonathanKohlhas): Replace with set number for actually using it, but
      // great for testing, makes the point at which threads switch random
      for (int i = 0; i < Random().nextInt(20); i++) {
        if (thread.state == ThreadState.dead ||
            (thread.state == ThreadState.suspended && !_inAtomicSection)) {
          break;
        }

        try {
          final inInitState = thread.state == ThreadState.init;
          if (inInitState) {
            thread.call(0);
          }
          if (thread._frame.closure == null) {
            thread.state = ThreadState.dead;
            break;
          } else if (thread._frame.closure!.isSlang) {
            thread._step();
          } else {
            //if we did just come from init state we don't run the continuation
            thread._runDartFunction(continuation: !inInitState);
          }
        } on SlangYield {
          thread.state = ThreadState.suspended;
        } catch (e, stack) {
          print(buildStackTrace());
          print("Error: $e");
          print("Stack: $stack");
          rethrow;
        }
      }
      if (!_inAtomicSection) {
        threads.removeWhere((t) => t.state == ThreadState.dead);
        if (threads.isNotEmpty) {
          current = (current + 1) % threads.length;
        }
      }
    }
    for (final thread in originalThreads) {
      thread.executionMode = ExecutionMode.dartStack;
    }
  }

  @override
  void pCall(int nargs, {DartFunction? then}) {
    _frame.continuation = then;
    final currentStack = _frame;
    try {
      call(nargs);
      newTable();
      pushValue(-1);
      push("ok");
      appendTable();
      pushValue(-1);
      pushValue(-3);
      appendTable();
      pop(1, 1);
    } on SlangYield {
      rethrow;
    } catch (e, stack) {
      var err = e;
      if (err is! SlangException) {
        err = SlangException("$err ${buildStackTrace()} $stack", _frame.currentInstructionLocation);
      }
      while (_frame != currentStack) {
        _popStack();
      }
      newTable();
      pushValue(-1);
      push("err");
      appendTable();
      pushValue(-1);
      err.toSlang(this);
      appendTable();
      if (debug.mode == DebugMode.runDebug) {
        debug.mode = DebugMode.step;
        print(err);
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
    _frame.push(value);
  }

  @override
  void pushDartFunction(DartFunction function) {
    push(Closure.dart(function));
  }

  @override
  void pushValue(int index) {
    _frame.push(_frame[index]);
  }

  @override
  void registerDartFunction(String name, DartFunction function) {
    // globals[name] = Closure.dart(function);
    pushDartFunction(function);
    setGlobal(name);
  }

  @override
  void replace(int index) {
    _frame[index] = _frame.pop();
  }

  @override
  void resume(int nargs) {
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
      push(null);
      return;
    }

    try {
      if (thread.state == ThreadState.running) {
        //remove the yield frame
        thread._popStack();
        for (final arg in args) {
          thread.push(arg);
        }
        while (thread._frame.closure != null) {
          if (thread._frame.closure!.isDart) {
            thread._runDartFunction(continuation: true);
          } else {
            //complete step over the yield call instruction
            // thread.addPc(1);
            thread._runSlangFunction();
          }
        }
      } else if (thread.state == ThreadState.init) {
        for (final arg in args) {
          thread.push(arg);
        }
        thread.call(args.length);
      }
      //completed normally => thread is dead
      thread.state = ThreadState.dead;
      if (thread._frame.top > 0) {
        push(thread._frame.pop());
      } else {
        push(null);
      }
    } on SlangYield {
      // take top of stack and put it on our stack
      if (thread._frame.top > 0) {
        push(thread._frame.pop());
      } else {
        push(null);
      }
      return;
    } catch (e, stack) {
      print(buildStackTrace());
      print("Error: $e");
      print("Stack: $stack");
      rethrow;
    }

    return;
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
    if (table is! SlangTable) {
      throw Exception('Expected SlangTable got ${table.runtimeType}');
    }
    _setTable(table, key, value);
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
    if (value is int) {
      _frame.push("int");
    } else if (value is double) {
      _frame.push("double");
    } else if (value is String) {
      _frame.push("string");
    } else if (value is bool) {
      _frame.push("bool");
    } else if (value is Closure) {
      _frame.push("function");
    } else if (value is SlangTable) {
      _frame.push("table");
    } else if (value is SlangVmImpl) {
      _frame.push("thread");
    } else {
      _frame.push("null");
    }
  }

  @override
  void yield() {
    throw SlangYield();
  }

  void _getTable(SlangTable table, Object key) {
    final value = table[key];
    if (value != null || table.metatable == null || table.metatable!["__index"] == null) {
      _frame.push(value);
      return;
    }
    final metatable = table.metatable!;
    final index = metatable["__index"];
    switch (index) {
      case Closure closure:
        _frame.push(closure);
        _frame.push(table);
        _frame.push(key);
        call(2);
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

    if (closure.prototype != null) {
      final proto = closure.prototype!;
      final nargs = proto.isVarArg ? proto.nargs - 1 : proto.nargs;
      final extraArgs = SlangTable();
      for (final (index, arg) in args.indexed) {
        if (index < nargs) {
          _frame.push(arg);
        } else {
          extraArgs.add(arg);
        }
      }
      if (proto.isVarArg) {
        _frame.push(extraArgs);
      }
    } else {
      for (final arg in args) {
        _frame.push(arg);
      }
    }
    if (closure.isSlang) {
      _frame.setTop(closure.prototype!.maxVarStackSize);
    }
    return closure;
  }

  void _pushStack([Closure? closure]) {
    _frame = SlangStackFrame(closure, _frame);
  }

  void _runDartFunction({bool continuation = false}) {
    if (continuation && _frame.continuation == null) {
      // throw Exception("Cannot run continuation without a continuation function");
      _popStack();
      _frame.push(null);
      return;
    }
    final function = continuation ? _frame.continuation! : _frame.closure!.dartFunction!;
    var returnsValue = function(this);
    //if we aren't already running the continuation and the function doesn't return before the continuation
    //we run the continuation if it exists
    if (!continuation && !returnsValue && _frame.continuation != null) {
      returnsValue = _frame.continuation!(this);
    }
    Object? returnValue;
    if (returnsValue) {
      returnValue = _frame.pop();
    }
    _popStack();
    _frame.push(returnValue);
  }

  void _runSlangFunction() {
    state = ThreadState.running;
    while (true) {
      if (_step()) {
        break;
      }
    }
  }

  void _setTable(SlangTable table, Object key, Object? value) {
    // table[key] = value;
    if (table[key] != null || table.metatable == null || table.metatable!["__newindex"] == null) {
      table[key] = value;
      return;
    }

    final metatable = table.metatable!;
    final newindex = metatable["__newindex"];
    switch (newindex) {
      case Closure closure:
        _frame.push(closure);
        _frame.push(table);
        _frame.push(key);
        _frame.push(value);
        call(3);
        return;
      case SlangTable table:
        _setTable(table, key, value);
        return;
      default:
        return;
    }
  }

  bool _step() {
    if (_frame.closure?.prototype == null) {
      throw (Exception("Cannot step while not inside slang function"));
    }
    final instruction = _frame.currentInstruction;
    final op = instruction!.op;
    addPc(1);
    debug._runDebugFunctionality();
    op.execute(this, instruction);
    if (op.name == OpCodeName.returnOp) {
      return true;
    }
    return false;
  }
}

class SlangYield implements Exception {
  SlangYield();
}
