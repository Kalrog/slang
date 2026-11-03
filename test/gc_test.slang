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
