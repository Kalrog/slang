import 'package:slang/src/stdlib/package_lib.dart';
import 'package:slang/src/table.dart';
import 'package:slang/src/vm/closure.dart';
import 'package:slang/src/vm/slang_vm.dart';

class SlangThreadsLib {
  static Map<String, DartFunction> functions = {
    "create": _create,
    "resume": _resume,
    "yield": _yield,
    "state": _state,
    "parallel": _parallel,
    "atomic": _atomic,
    "suspend": _suspend,
    "wake": _wake,
    "current": _current,
    "id": _id,
  };

  static const String slangFunctions = '''
  local thread = require("slang/thread"); 
  local table = require("slang/table");
  local atomic = thread.atomic;

  local semaphore = {}; 
  func semaphore.new(count){
    local s = {};
    s.count = count;
    s.waiting = {};
    s.meta = {__index:semaphore};
    return s;
  }

  func semaphore.wait(self){
    atomic{
      self.count = self.count - 1;
      if (self.count < 0){
        append(self.waiting,thread.current());
        thread.suspend();
      }
    }
  }

  func semaphore.signal(self){
    atomic{
      self.count = self.count + 1;
      if (self.count <= 0){
        local t = table.dequeue(self.waiting);
        thread.wake(t);
      }
    }
  }

  local channel = {};
  func channel.new(capacity){
    local c = {};
    c.capacity = capacity;
    c.queue = {};
    c.use_queue = semaphore.new(1);
    c.empty_count= semaphore.new(capacity);
    c.full_count = semaphore.new(0);
    c.meta = {__index:channel};
    return c;
  }

  func channel.send(self,value){
    self.empty_count:wait();
    self.use_queue:wait();
    append(self.queue,value);
    self.use_queue:signal();
    self.full_count:signal();
  }

  func channel.receive(self){
    self.full_count:wait();
    self.use_queue:wait();
    local value = table.dequeue(self.queue);
    self.use_queue:signal();
    self.empty_count:signal();
    return value;
  }

  thread.semaphore = semaphore;
  thread.channel = channel;
''';

  /// create(func) or create { ... }
  /// Create a new thread with the given function.
  /// The execution of the thread will not start until the thread is resumed or run in parallel.
  static bool _create(SlangVm vm) {
    vm.createThread();
    return true;
  }

  /// resume(thread,[value])
  /// Resume the given thread, optionally passing a value.
  /// When starting a thread, the value is passed to the thread function.
  /// When resuming a thread, the value is returned by the yield function.
  static bool _resume(SlangVm vm) {
    vm.resume(vm.getTop() - 1);
    return true;
  }

  /// yield([value])
  /// Yield the current thread, optionally returning a value.
  static bool _yield(SlangVm vm) {
    vm.yield();
    return false;
  }

  /// state([thread])
  /// Get the state of the current thread or the given thread.
  static bool _state(SlangVm vm) {
    var thread = vm;
    if (vm.getTop() == 1) {
      thread = vm.toAny(-1) as SlangVm;
    }
    vm.push(thread.state.name);
    return true;
  }

  /// parallel(...threads)
  /// Run the given threads in preemptive mode.
  /// This will run the threads with preemption, meaning that the threads can be
  /// paused and resumed by the VM. Because slang is implemented in Dart, and Dart
  /// does not support true parallelism, there will still be only one thread running, but
  /// unlike cooperative mode using yield and resume, the VM will decide when to pause and resume
  /// the threads and may do so in the middle of any operation.
  /// This is useful for running multiple threads that may block or wait for some event.
  /// Shedueling of the threads does not happen in a global system, but rather on the vm
  /// that called the parallel function, meaning, it is not possible to call parallel inside
  /// a thread that is already running in parallel mode. The parallel function itself has no means
  /// of recovering if it is preempted itself.
  ///
  /// Implementation Details:
  /// WARNING: There is no guarantee that these will stay the same and you should never write slang
  /// code that depends on the behavior described here. The purpose of this description is purely to
  /// aid in understanding the behavior of the function and to help in debugging or reporting errors.
  ///
  /// Initially a list of all the threads is created to be run.
  /// The threads are scheduled in a round-robin fashion, meaning that each thread will run for a
  /// set number of instructions before the next thread is run.
  /// Any thread whose function has returned is removed from the list of threads to be run.
  /// Threads that are suspended are skipped but may be resumed in the future.
  /// The parallel execution will stop when all threads have returned or are suspended.
  static bool _parallel(SlangVm vm) {
    //take any table args and push each value inside onto the stack
    List<SlangVm> threads = [];
    for (var i = 0; i < vm.getTop(); i++) {
      if (vm.checkThread(i)) {
        threads.add(vm.toThread(i));
      } else if (vm.checkTable(i)) {
        final table = vm.toAny(i) as SlangTable;
        threads.addAll(table.values.cast<SlangVm>());
      } else {
        throw ArgumentError("parallel expects a thread or a table of threads");
      }
    }
    vm.pop(0, vm.getTop());
    for (var thread in threads) {
      vm.push(thread);
    }
    vm.parallel(vm.getTop());
    return false;
  }

  /// atomic(func) or atomic { ... }
  /// Run the given function or block in an atomic section.
  /// This will prevent any other thread from running until the atomic section is done.
  /// Atomic should be used with care and has some restrictions:
  /// - Cannot yield inside atomic section
  /// - Cannot call parallel inside atomic section
  /// - Cannot call atomic inside atomic section
  /// If any of these restrictions are violated, behavior is undefined, although in most cases
  /// an exception will be thrown, but in some cases a deadlock might occur.
  static bool _atomic(SlangVm vm) {
    vm.startAtomic();
    try {
      final mode = vm.executionMode;
      vm.executionMode = ExecutionMode.dartStack;
      vm.call(0);
      vm.executionMode = mode;
    } on SlangYield {
      throw Exception("Cannot yield inside atomic section");
    } finally {
      vm.endAtomic();
    }
    return false;
  }

  /// suspend([thread])
  /// Suspend the current thread or the given thread.
  static bool _suspend(SlangVm vm) {
    var thread = vm;
    if (vm.getTop() == 1) {
      thread = vm.toAny(-1) as SlangVm;
    }
    thread.state = ThreadState.suspended;
    return false;
  }

  /// wake(thread)
  /// Wake up the given thread, unlike resume, this will not start the thread
  /// so it will only work in preemptive/parallel mode.
  static bool _wake(SlangVm vm) {
    final thread = vm.toAny(-1) as SlangVm;
    thread.state = ThreadState.running;
    return false;
  }

  /// current()
  /// Returns a reference to the current thread.
  static bool _current(SlangVm vm) {
    vm.push(vm);
    return true;
  }

  static bool _id(SlangVm vm) {
    vm.push(vm.id);
    return true;
  }

  static void register(SlangVm vm) {
    vm.newTable(0, 0);
    vm.pushValue(-1);
    vm.push("atomic");
    vm.push(false);
    vm.setTable();
    vm.setGlobal("__thread");
    vm.newTable(0, 0);
    for (var entry in functions.entries) {
      vm.pushValue(-1);
      vm.push(entry.key);
      vm.pushDartFunction(entry.value);
      vm.setTable();
    }
    SlangPackageLib.preloadModuleValue(vm, "slang/thread");
    vm.compile(slangFunctions, origin: "slang/thread");
    vm.call(0);
  }
}
