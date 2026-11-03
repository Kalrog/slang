local t = require("slang/test")
local isolate = require("slang/isolate")
local str = require("slang/string")

// A spawned function crosses as bytecode: it uses globals and what it
// requires itself, never locals of the code around it (so the tests'
// workers start with require("slang/isolate")).

local func raises(f, needle){
  local r = pcall(f)
  assert(r[0] == "err", "expected an error")
  local msg = r[1].message
  assert(str.contains(msg, needle), concat("unexpected error: ", msg))
  return r[1]
}

t.group("isolates"){
  t.test("spawn and join"){
    assert(isolate.available())
    local w = isolate.spawn(func(a, b){ return a + b }, 2, 3)
    assert(w:join() == 5)
    assert(not w.running)
    // a result can be joined again
    assert(w:join() == 5)
    assert(isolate.id() == 0)
    local inner = isolate.spawn(func(){ return require("slang/isolate").id() })
    assert(inner:join() == inner.id)
  }

  t.test("an isolate finds modules where its caller does: paths and packages"){
    local saved = __PACKAGES.packages
    __PACKAGES.packages = {demo: {dir: "/nowhere", paths: {"/nowhere"}, suffixes: {}, missing: false}}
    local w = isolate.spawn(func(){
      local p = __PACKAGES.packages
      return {p.demo.dir, len(__PACKAGES.search_paths)}
    })
    __PACKAGES.packages = saved
    local r = w:join()
    assert(r[0] == "/nowhere" and r[1] == len(__PACKAGES.search_paths))
  }

  t.test("channels carry values both ways"){
    local work = isolate.channel()
    local done = isolate.channel()
    local w = isolate.spawn(func(work, done){
      local iso = require("slang/isolate")
      local n = 0
      for(let local job in iso.each(work)){
        done:send({id: job.id, square: job.x * job.x})
        n = n + 1
      }
      return n
    }, work, done)
    for(local i = 1; i <= 50; i = i + 1){
      work:send({id: i, x: i})
    }
    work:close()
    for(local i = 1; i <= 50; i = i + 1){
      local r = done:receive()
      assert(r.id == i and r.square == i * i)
    }
    assert(w:join() == 50)
  }

  t.test("values are copied, with cycles, sharing and metatables"){
    local shape = {__index: {area: func(s){ return s.w * s.h }}}
    local box = {w: 2, h: 3, @meta: shape}
    local msg = {box: box, again: box, list: {1, 2.5, "three", true}}
    msg.self = msg
    local w = isolate.spawn(func(m){
      m.box.w = 10
      return {
        same: m.again == m.box,
        cycle: m.self == m,
        area: m.box:area(),
        list: m.list,
      }
    }, msg)
    local r = w:join()
    assert(r.same and r.cycle)
    assert(r.area == 30)
    assert(r.list[1] == 2.5 and r.list[2] == "three" and r.list[3] == true)
    // the sender's table is untouched
    assert(box.w == 2)
  }

  t.test("functions cross as bytecode"){
    local double = func(x){ return x * 2 }
    local w = isolate.spawn(func(f){ return {f(21), f} }, double)
    local r = w:join()
    assert(r[0] == 42 and r[1](4) == 8)
    local y = 1
    raises(func(){ isolate.spawn(func(){ return y }) }, "uses y")
    raises(func(){ isolate.spawn(print) }, "native function")
  }

  t.test("what cannot be sent"){
    local ch = isolate.channel()
    raises(func(){ ch:send(null) }, "cannot send null")
    raises(func(){ ch:send(require("slang/thread").create(func(){})) }, "coroutine")
    raises(func(){ ch:send({b: require("slang/buffer").new("uint8_t", 4)}) }, "only buffer.shared")
    assert(ch.len == 0)
  }

  t.test("an error reaches join with its traceback"){
    local w = isolate.spawn(func(){
      local func deep(){ raise("boom") }
      deep()
    })
    local e = raises(func(){ w:join() }, "boom")
    assert(str.contains(e.stack, "deep"), e.stack)
    assert(e.location.line > 0)
    // a raised table keeps its fields
    local w2 = isolate.spawn(func(){ raise({message: "custom", code: 7}) })
    local e2 = raises(func(){ w2:join() }, "custom")
    assert(e2.code == 7)
    // a result that cannot cross is an error
    local w3 = isolate.spawn(func(){ return require("slang/thread").create(func(){}) })
    raises(func(){ w3:join() }, "coroutine")
  }

  t.test("try_send, try_receive and capacity"){
    local ch = isolate.channel({capacity: 2})
    assert(ch.capacity == 2)
    assert(isolate.channel().capacity == null)
    assert(ch:try_receive() == null)
    assert(ch:try_send(1) and ch:try_send(2))
    assert(not ch:try_send(3))
    assert(ch.len == 2)
    assert(ch:try_receive() == 1)
    // a full channel blocks the sender until a receiver makes room
    ch:send(3)
    local w = isolate.spawn(func(ch){
      for(local i = 4; i <= 20; i = i + 1){ ch:send(i) }
      ch:close()
    }, ch)
    local got = {}
    for(let local v in isolate.each(ch)){ append(got, v) }
    w:join()
    assert(len(got) == 19 and got[0] == 2 and got[18] == 20)
    raises(func(){ isolate.channel({capacity: 0}) }, "capacity")
  }

  t.test("close"){
    local ch = isolate.channel()
    ch:send("last")
    ch:close()
    assert(ch.closed)
    raises(func(){ ch:send(1) }, "closed")
    assert(ch:receive() == "last")
    assert(ch:receive() == null)
    assert(ch:try_receive() == null)
  }

  t.test("channels and isolates cross by reference"){
    local ch = isolate.channel()
    local back = isolate.channel()
    ch:send(back)
    local same = ch:receive()
    assert(same == back)
    local w = isolate.spawn(func(ch){
      local reply = ch:receive()
      reply:send("pong")
    }, ch)
    ch:send(back)
    assert(back:receive() == "pong")
    w:join()
    // an isolate handle can be joined from another isolate
    local slow = isolate.spawn(func(){ return "slow" })
    local waiter = isolate.spawn(func(other){ return concat(other:join(), "!") }, slow)
    assert(waiter:join() == "slow!")
  }

  t.test("kill"){
    local busy = isolate.spawn(func(){ for(true){ } })
    busy:kill()
    assert(not busy.running)
    assert(busy:join() == null)
    // a receive that waits is woken; try/catch cannot keep it alive
    local blocked = isolate.spawn(func(ch){
      for(true){
        try { ch:receive() } catch(local e) { }
      }
    }, isolate.channel())
    blocked:kill()
    assert(blocked:join() == null)
    // killing one that has ended does nothing
    local quick = isolate.spawn(func(){ return 1 })
    assert(quick:join() == 1)
    assert(quick:kill() == null and quick:join() == 1)
  }

  t.test("two isolates fill halves of one shared buffer"){
    local buffer = require("slang/buffer")
    local n = 1000
    local half = 500
    local b = buffer.shared("int32", n)
    assert(b.shared and not buffer.new("int32", 1).shared)
    local func fill(part, from){
      for(local i = 0; i < len(part); i = i + 1){
        part[i] = from + i
      }
      return len(part)
    }
    local low = isolate.spawn(fill, b:slice(0, half), 0)
    local high = isolate.spawn(fill, b:slice(half), half)
    assert(low:join() == half and high:join() == half)
    for(local i = 0; i < n; i = i + 1){
      assert(b[i] == i)
    }
    raises(func(){ buffer.shared("void *", 1) }, "not a number type")
  }

  t.test("lock makes several writes one"){
    local buffer = require("slang/buffer")
    local counter = buffer.shared("int64", 1)
    local func add(c, times){
      for(local i = 0; i < times; i = i + 1){
        c:lock(func(){ c[0] = c[0] + 1 })
      }
    }
    local a = isolate.spawn(add, counter, 300)
    local b = isolate.spawn(add, counter, 300)
    a:join()
    b:join()
    assert(counter[0] == 600, string(counter[0]))
    counter:lock()
    raises(func(){ counter:lock() }, "holds the lock")
    counter:unlock()
    raises(func(){ counter:unlock() }, "not held")
    raises(func(){ buffer.new("int", 1):lock() }, "not a shared buffer")
  }
}
