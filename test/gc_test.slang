local t = require("slang/test")
local time = require("slang/time")
local math = require("slang/math")
local vm = require("slang/vm")
local str = require("slang/string")

t.group("collector"){
  // interned strings the collector removed used to leave tombstones that
  // the intern table counted as free, so after enough distinct short
  // strings every lookup of a new one probed the whole table
  t.test("distinct short strings stay flat per string"){
    local n = 40000
    local func batch(from){
      local t0 = time.clock()
      local s = null
      for(local i = from; i < from + n; i = i + 1){
        s = concat("item", i)
      }
      return time.clock() - t0
    }
    // the best of three on each side, against scheduler noise; the
    // cliff was a factor of 100 and more
    local first = batch(0)
    first = math.min(first, batch(n), batch(2 * n))
    local last = batch(3 * n)
    last = math.min(last, batch(4 * n), batch(5 * n))
    assert(last < first * 10, concat("last batch ", string(last), " vs first ", string(first)))
  }
}

t.group("collector: vm.collect and vm.gc"){
  local gc = vm.gc
  local saved = {growth: gc.growth, minimum: gc.minimum, automatic: gc.automatic}
  t.teardown{
    gc.growth = saved.growth
    gc.minimum = saved.minimum
    gc.automatic = saved.automatic
  }
  t.test("collect runs a collection now"){
    local n = gc.collections
    vm.collect()
    // (a cycle that was running is finished first: that counts too)
    assert(gc.collections == n + 1 or gc.collections == n + 2, gc.collections)
    n = gc.collections
    vm.collect()
    assert(gc.collections == n + 1, gc.collections)
    assert(gc.in_use > 0)
  }
  t.test("the settings are properties"){
    assert(gc.growth == 2.0 and gc.minimum == 8 * 1024 * 1024 and gc.automatic, "defaults")
    gc.growth = 1.5
    gc.minimum = 1024 * 1024
    assert(gc.growth == 1.5 and gc.minimum == 1024 * 1024)
    assert(gc.next != null and gc.next > 0, gc.next)
  }
  t.test("without automatic collections only collect frees"){
    gc.automatic = false
    assert(gc.next == null)
    local n = gc.collections
    for(local i = 0; i < 2000; i = i + 1){
      local junk = {i, concat("x", string(i))}
    }
    assert(gc.collections == n, "no collection on its own")
    vm.collect()
    assert(gc.collections == n + 1)
    gc.automatic = true
    assert(gc.next != null)
  }
  t.test("bad settings raise, counters are read-only"){
    local func fails(f, part){
      local r = pcall(f)
      assert(r[0] == "err" and str.index_of(r[1].message, part) >= 0, r[1].message or "no error")
    }
    fails(func(){ gc.growth = 1 }, "at least 1.1")
    fails(func(){ gc.minimum = -1 }, "negative")
    fails(func(){ gc.automatic = 1 }, "bool")
    fails(func(){ gc.in_use = 0 }, "read-only")
    fails(func(){ gc.collections = 0 }, "read-only")
  }
}

t.group("collector: on_collect, weak tables, keep"){
  t.test("a finalizer runs once its object is unreachable"){
    local log = {}
    local o = {name: "o"}
    // the finalizer refers to its object: that does not keep it alive
    vm.on_collect(o, func(x){ append(log, concat(x.name, " ", string(o == null))) })
    vm.collect()
    assert(len(log) == 0, "o is alive")
    o = null
    vm.collect()
    assert(log == {"o true"}, str.join(log, ","))
  }
  t.test("one finalizer per value: replaced, removed"){
    local log = {}
    local a = {}
    vm.on_collect(a, func(){ append(log, "first") })
    vm.on_collect(a, func(){ append(log, "second") })
    local b = {}
    vm.on_collect(b, func(){ append(log, "b") })
    vm.on_collect(b, null)
    a = null
    b = null
    vm.collect()
    assert(log == {"second"}, str.join(log, ","))
    local r = pcall(vm.on_collect, "text", func(){})
    assert(r[0] == "err" and str.index_of(r[1].message, "not collected") >= 0)
  }
  t.test("an isolate runs its finalizers when it ends"){
    local isolate = require("slang/isolate")
    local ch = isolate.channel()
    isolate.spawn(func(ch){
      require("slang/vm").on_collect({}, func(){ ch:send("finalized") })
    }, ch):join()
    local got = null
    for(local i = 0; i < 100 and got == null; i = i + 1){
      got = ch:try_receive()
      if(got == null){ time.sleep(5) }
    }
    assert(got == "finalized", got)
  }
  t.test("weak values let go, strings and what is held stay"){
    local cache = vm.weak_values()
    local held = {2}
    cache.gone = {1}
    cache.held = held
    cache.text = "kept"
    cache[0] = {3}
    cache[1] = held
    vm.collect()
    assert(cache.gone == null and cache.held == held and cache.text == "kept")
    assert(cache[0] == null and cache[1] == held, "list indices keep theirs")
    local r = vm.weak({})
    local r2 = vm.weak(held)
    vm.collect()
    assert(r.value == null and r2.value == held)
  }
  t.test("weak keys are ephemerons: a value referring to its key"){
    local side = vm.weak_keys()
    local key = {}
    side[key] = {owner: key}
    local other = {}
    side[other] = {owner: other}
    other = null
    vm.collect()
    local n = 0
    for(let local e in entries(side)){
      n = n + 1
    }
    assert(n == 1 and side[key].owner == key, n)
  }
  t.test("a buffer's keep lives as long as the buffer and its slices"){
    local buffer = require("slang/buffer")
    local freed = false
    local owner = {}
    vm.on_collect(owner, func(){ freed = true })
    local px = buffer.new("uint8", 4)
    px.keep = owner
    owner = null
    local half = px:slice(0, 2)
    px = null
    vm.collect()
    assert(not freed and type(half.keep) == "null", "the slice keeps the buffer, and so the owner")
    half = null
    vm.collect()
    assert(freed)
  }
}

// The collector marks in steps between which the program runs: values that
// reach old objects while marking (stores, moved elements, closed
// upvalues, coroutine stacks) must survive. The GC-stress build steps every
// few KB and checks every cycle.
t.group("collector: incremental marking"){
  t.test("values moved and stored while marking survive"){
    local big = {}
    for(local i = 0; i < 200; i = i + 1){
      big[i] = {n: i}
    }
    local keyed = {}
    for(local i = 0; i < 200; i = i + 1){
      keyed[concat("k", string(i))] = {n: i}
    }
    // closures over locals that are closed (the value leaves the stack)
    local getters = {}
    for(local i = 0; i < 50; i = i + 1){
      local held = {n: i}
      append(getters, func(){ return held })
    }
    // a coroutine whose stack holds a table between resumes
    local thread = require("slang/thread")
    local co = thread.create(func(){
      local mine = {n: "co"}
      for(local i = 0; i < 100; i = i + 1){
        thread.yield(mine.n)
      }
    })
    for(local round = 0; round < 40; round = round + 1){
      // garbage, so that steps run in between
      for(local j = 0; j < 200; j = j + 1){
        local junk = {j, j, j}
      }
      // shift a list down, insert into it, delete hash keys (compaction)
      remove(big, 0)
      append(big, {n: 1000 + round})
      keyed[concat("k", string(round))] = null
      keyed[concat("new", string(round))] = {n: -round}
      assert(thread.resume(co) == "co")
    }
    // the running cycle ends (in the GC-stress build: checked) and a whole
    // one runs
    vm.collect()
    for(let local v in values(big)){
      assert(type(v.n) == "int")
    }
    for(let local e in entries(keyed)){
      assert(type(e[1].n) == "int")
    }
    for(local i = 0; i < 50; i = i + 1){
      assert(getters[i]().n == i)
    }
    assert(len(big) == 200 and big[199].n == 1039)
  }

  t.test("step(ms) works on a cycle in a time budget"){
    // nothing to do yet right after a collection
    vm.collect()
    assert(vm.gc:step(1) == false)
    local keep = {}
    local running = false
    for(local round = 0; round < 200 and not running; round = round + 1){
      for(local i = 0; i < 2000; i = i + 1){
        keep[i] = {i}
      }
      running = vm.gc:step(0.01)
    }
    // a cycle started; steps finish it
    local n = vm.gc.collections
    for(local i = 0; i < 100000 and vm.gc:step(5); i = i + 1){}
    assert(vm.gc.collections == n + 1, string(vm.gc.collections - n))
    assert(len(keep) == 2000 and keep[1999][0] == 1999)
  }

  t.test("longest_step is measured and resets to 0"){
    local junk = null
    for(local i = 0; i < 20000; i = i + 1){
      junk = {i, i}
    }
    assert(vm.gc.longest_step >= 0.0)
    vm.gc.longest_step = 0
    assert(vm.gc.longest_step == 0.0)
    local r = pcall(func(){ vm.gc.longest_step = 5 })
    assert(r[0] == "err")
  }
}
