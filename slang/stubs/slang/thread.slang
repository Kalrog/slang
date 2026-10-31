// slang/thread: cooperative coroutines, built into the VM. A coroutine runs
// only while it is resumed, until it yields or returns; nothing runs in
// parallel. slang/async builds its tasks on them.
//
//   local thread = require("slang/thread")
//   local co = thread.create(func(a){
//     local b = thread.yield(a + 1)
//     return b * 2
//   })
//   thread.resume(co, 1)    // 2
//   thread.resume(co, 10)   // 20
//   thread.state(co)        // "dead"

// A coroutine; type() of it is "thread". The main program runs on one
// too, the main thread.
// type Coroutine = any
local m = {}

// create(f: function) -> Coroutine
// A new coroutine running f; it starts on the first [resume].
func m.create(f){}

// resume(co: Coroutine, ...values) -> any
// Runs co until it yields or returns, and gives back the value it yields
// or returns. On the first resume the values are the arguments of its
// function; later the first value is the result of the [yield] it is
// suspended in. An error in co is raised by resume and ends co. Resuming
// a finished coroutine returns null; resuming a running one raises an
// error.
func m.resume(co, ...values){}

// yield(value?) -> any
// Suspends the current coroutine; the [resume] that ran it returns value.
// Gives back the first value the next resume passes. Raises an error on
// the main thread.
func m.yield(value){}

// state(co?: Coroutine) -> string
// "init", "running", "suspended" or "dead": the state of co, or of the
// current coroutine.
func m.state(co){}

// current() -> Coroutine
// The running coroutine (or the main thread).
func m.current(){}

// id() -> int
// The id of the running coroutine.
func m.id(){}

return m
