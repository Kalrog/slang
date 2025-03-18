local t = require("slang/test")
local thread = require("slang/thread")

t.group("threads"){
  t.test("thread creation"){
    local thr = thread.create(func(){
      return 1
    })
    assert(type(thr) == "thread", "thread.create should return a thread object")
  }
  t.test("thread yield"){
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
  } 
  t.test("thread return"){
    local thr = thread.create(func(){
      return 1
    })
    local v = thread.resume(thr)
    assert(v == 1, "thread.resume should return the value returned by the thread function")
    assert(thread.state(thr) == "dead", "thread.state should return dead for a thread that has returned")
  }
  t.test("resume value for initialization"){
    local thr = thread.create(func(v){
      return v
    })
    local value = thread.resume(thr, 123)
    assert(value == 123, "thread.resume should pass the value to the thread function")
  }
  t.test("yield should return value passed to resume"){
    local summer = thread.create(func(v){
      sum = v
      for(true){
        v = thread.yield(sum)
        sum = sum + v
      }
    })
    assert(thread.resume(summer, 1) == 1, "thread.resume should return the value passed to thread.yield")
    assert(thread.resume(summer, 2) == 3, "thread.resume should return the value passed to thread.yield")
    assert(thread.resume(summer, 3) == 6, "thread.resume should return the value passed to thread.yield")
    assert(thread.resume(summer, 4) == 10, "thread.resume should return the value passed to thread.yield")
  }
  t.test("thread complex example"){
    //elixir style state thread
    local state_thread = thread.create(func(){
      local state = {}
      local msg 
      for(true){
        if (msg == nil){
          msg = thread.yield()
        } else if(msg[0] == "put"){
          state[msg[1]] = msg[2]
          msg = thread.yield(msg[2])
        } else if(msg[0] == "get"){
          msg = thread.yield(state[msg[1]])
        } else if(msg[0] == "delete"){
          state[msg[1]] = nil
          msg = thread.yield()
        } else if(msg[0] == "clear"){
          state = {}
          msg = thread.yield()
        }else{
          msg = thread.yield()
        }
      }
    })
    local func store(key, value){
      return thread.resume(state_thread, {"put", key, value})
    }
    local func get(key){
      return thread.resume(state_thread, {"get", key})
    }
    local func delete(key){
      return thread.resume(state_thread, {"delete", key})
    }
    local func clear(){
      return thread.resume(state_thread, {"clear"})
    }
    thread.resume(state_thread, nil)
    assert(store("a", 1) == 1, "store should return the value passed to thread.yield")
    assert(store("b", 2) == 2, "store should return the value passed to thread.yield")
    assert(get("a") == 1, "get should return the value stored")
    assert(get("b") == 2, "get should return the value stored")
    assert(delete("a") == nil, "delete should return nil")
    assert(get("a") == nil, "get should return nil after delete")
    assert(clear() == nil, "clear should return nil")
    assert(get("b") == nil, "get should return nil after clear")
  }
  t.test("thread yield in called function"){
    local func theYielder(){
      thread.yield(1)
    }
    local thr = thread.create(func(){
      theYielder()
      print("return inside worked\n")
      return 2
    })
    assert(thread.resume(thr) == 1, "thread.resume should return the value passed to thread.yield")
    print("yield 1 worked\n")
    assert(thread.resume(thr) == 2, "thread.resume should return the value returned by the thread function")
    print("return 2 worked\n")
  }
  t.test("thread yields in deeply nested call with loops"){
    func counter(){
      for(local i = 0; i < 10; i = i + 1){
        thread.yield(i)
      }
    }
    func relay(){
      for(local i = 0; i < 10; i = i + 1){
        counter()
      }
    }
    local thr = thread.create(func(){
      relay()
    })
    for(local i = 0; i < 100; i = i + 1){
      assert(thread.resume(thr) == i % 10, "thread.resume should return the value passed to thread.yield")
    }
  }
}