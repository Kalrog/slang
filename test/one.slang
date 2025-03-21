local thread = require("slang/thread");
    local thr = thread.create(func(){
      for(local i = 0; i < 10; i = i + 1){
        thread.yield(i)
      }
    })
    local v = thread.resume(thr)
    assert(v == 0, "thread.resume should return the value passed to thread.yield")
    v = thread.resume(thr)
    assert(v == 1, "thread.resume should return the value passed to thread.yield")
    v = thread.resume(thr)
    assert(v == 2, "thread.resume should return the value passed to thread.yield")
    v = thread.resume(thr)
    assert(v == 3, "thread.resume should return the value passed to thread.yield")
    v = thread.resume(thr)
    assert(v == 4, "thread.resume should return the value passed to thread.yield")
