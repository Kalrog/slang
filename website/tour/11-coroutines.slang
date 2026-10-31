// Coroutines
//
// A coroutine is a function that can pause. `thread.yield(v)` suspends it
// and hands `v` to whoever resumed it; the next `thread.resume` continues
// where it stopped. Generators, state machines and the async runtime are
// built on them.
local thread = require("slang/thread")

local numbers = thread.create(func(){
  local a = 0
  local b = 1
  for(true){
    thread.yield(a)
    local next = a + b
    a = b
    b = next
  }
})

for(local i = 0; i < 10; i = i + 1){
  print(thread.resume(numbers), " ")
}
print("\n", thread.state(numbers), "\n")
