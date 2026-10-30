// slang/thread: cooperative coroutines, built into the VM. A coroutine runs
// only while it is resumed, until it yields or returns.
//   local co = thread.create(func(a){
//     local b = thread.yield(a + 1)
//     return b * 2
//   })
//   thread.resume(co, 1)    // 2
//   thread.resume(co, 10)   // 20
local m = {}

// create(f) -> a new coroutine running f; it starts on the first resume
func m.create(f){}

// resume(co, ...values) -> the value co yields or returns. On the first
// resume the values are the arguments of its function; later the first
// value is the result of the yield it is suspended in. An error in co is
// raised by resume and ends co. Resuming a finished coroutine returns
// null; resuming a running one raises an error.
func m.resume(co, ...values){}

// yield([value]) -> the first value the next resume passes: suspends the
// current coroutine, and resume returns value. Raises an error on the main
// thread.
func m.yield(value){}

// state([co]) -> "init", "running", "suspended" or "dead": the state of co,
// or of the current coroutine
func m.state(co){}

// current() -> the running coroutine (or the main thread)
func m.current(){}

// id() -> the id of the running coroutine, an int
func m.id(){}

return m
