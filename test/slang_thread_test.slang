local t = require("slang/test")
local thread = require("slang/thread")
local semaphore = thread.semaphore
local math = require("slang/math")

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
  t.group("channels"){
    t.test("send and receive"){
      local channel = thread.channel.new(5)
      channel:send(1)
      assert(channel:receive() == 1, "channel:receive should return the value sent")
       
      channel:send(2)
      channel:send(3)
      assert(channel:receive() == 2, "channel:receive should return the value sent")
      assert(channel:receive() == 3, "channel:receive should return the value sent")
    }
    t.test("blocking"){
      local ch = thread.channel.new(1)
      local trblocking= thread.create(func(){
        ch:receive()
        assert(false, "channel:receive should block") 
      })
      thread.parallel(trblocking)

    }

  }
  t.group("preemptive threads"){
    t.test("producer consumer"){
      local output = {}
      local channel = thread.channel.new(5)
      local producer = thread.create(func(){
        for(local i = 0; i < 10; i = i + 1){
          channel:send(i) 
        }
      }) 
      local consumer = thread.create(func(){
        for(true){
          local value = channel:receive()
          append(output, value * value)
        }
      })
      thread.parallel(producer, consumer)
      assert(len(output) == 10, "output should have 10 elements")
      for(local i = 0; i < 10; i = i + 1){
        assert(output[i] == i * i, "output should have the square of the input")
      }
    }
    t.test("producer consumer with random waiting"){
      local func random_wait(){
        local wait_time = math.random(1, 20)
        for(local i = 0; i < wait_time; i = i + 1){
        }
      }

      local output = {}
      local channel = thread.channel.new(5)
      local producer = thread.create(func(){
        for(local i = 0; i < 10; i = i + 1){
          random_wait()
          channel:send(i) 
        }
      })
      local consumer = thread.create(func(){
        for(true){
          random_wait()
          local value = channel:receive()
          append(output, value * value)
        }
      })
      thread.parallel(producer, consumer)
      assert(len(output) == 10, "output should have 10 elements")
      for(local i = 0; i < 10; i = i + 1){
        assert(output[i] == i * i, "output should have the square of the input")
      }
      
    }

    t.test("rendezvous"){
      local a = 1;
      local b = 1;
      local aArrived = semaphore.new(0)
      local bArrived = semaphore.new(0)
      local ta = thread.create{
        a = a + 5;
        aArrived:signal()
        bArrived:wait()
        b = b * 10;
      }
      local tb = thread.create{
        b = b + 6;
        bArrived:signal()
        aArrived:wait()
        a = a * 15;
      }
      print("a: ", a, " b: ", b, "\n")
      //if the rendezvous is working the result should be
      // a = (1+5)*15 = 90 and not a = (1*15) + 5 = 20
      // b = (1+6)*10 = 70 and not b = (1*10) + 6 = 16
      
      thread.parallel(ta, tb)
      assert(a == 90, "a should be 90")
      assert(b == 70, "b should be 70")
    }
    t.test("mutex"){
      local a = 1;
      local mutex = semaphore.new(1);
      local ta = thread.create{
        for(local i = 0; i < 100; i = i + 1){
          //aquire a mutex
          mutex:wait();
          a = a + 1;
          //release the mutex
          mutex:signal();
        }
      }
      local tb = thread.create{
        for(local i = 0; i < 100; i = i + 1){
          //aquire a mutex
          mutex:wait();
          a = a - 1;
          //release the mutex
          mutex:signal();
        }
      }
      thread.parallel(ta, tb)
      print("a: ", a, "\n")
      assert(a == 1, "a should be 1")
    }
    t.test("barrier"){
      local didThreads = {};
      local threads = {};
      local barrierCount = 0;
      local barrierMutex = semaphore.new(1);
      local turnstile1 = semaphore.new(0);
      local turnstile2 = semaphore.new(1);

      local func waitBarrier(){
        barrierMutex:wait();
          barrierCount = barrierCount + 1;
          if(barrierCount == 20){
            turnstile2:wait();
            turnstile1:signal();
          }
        barrierMutex:signal();
        

        turnstile1:wait();
        turnstile1:signal();
      }
      local func resetBarrier(){
        barrierMutex:wait();
          barrierCount = barrierCount - 1;
          if(barrierCount == 0){
            turnstile1:wait();
            turnstile2:signal();
          }
        barrierMutex:signal();
        

        turnstile2:wait();
        turnstile2:signal();
      }

      for(local i = 0; i < 20; i = i + 1){
        local ta = thread.create{
          for(local g = 0; g < 10; g = g + 1){
            for(local i = 0; i < math.random(1,10); i = i + 1){}
            didThreads[i] = true;
            waitBarrier();
            for(local j = 0; j < 20; j = j + 1){
              assert(didThreads[j], i, " did ", j)
            }
            resetBarrier();
            didThreads[i]=false;
          }
        }
        append(threads,ta)
        append(didThreads,false)
      }
      thread.parallel(threads)
    }
  }
}