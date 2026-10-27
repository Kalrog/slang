// the async/await extension
extension "extensions/async"
local t = require("slang/test")
local str = require("slang/string")
local a = require("slang/async")

async func double_later(x){
  await a.sleep(1)
  return x * 2
}

local async func local_one(){
  return await a.value(1)
}

t.group("async syntax"){
  t.test("async functions return futures and await unwraps them"){
    local r = a.main(func(){
      local f = double_later(21)
      assert(type(f) == "Future")
      local anon = async func(x){ return (await double_later(x)) + 1 }
      return {await f, await anon(1), await local_one()}
    })
    assert(r == {42, 3, 1}, concat("results ", r))
  }
  t.test("await binds like a call"){
    local r = a.main(func(){
      local t = {f: double_later}
      local v = await t.f(2) + await a.value(10) * 2
      return v
    })
    assert(r == 24, concat("v ", r))
  }
  t.test("await for consumes a stream"){
    local r = a.main(func(){
      local c = a.controller()
      a.run(func(){
        for(local i = 1; i <= 3; i = i + 1){
          await a.sleep(1)
          c.add({n: i})
        }
        c.close()
      })
      local seen = {}
      await for(let {n: local n} in c.stream){
        append(seen, n)
        if(n == 2){ append(seen, "two") }
      }
      return seen
    })
    assert(r == {1, 2, "two", 3}, concat("seen ", r))
  }
  t.test("errors raised in async functions arrive at the awaiter"){
    local r = a.main(func(){
      local failing = async func(){ await a.sleep(1) error("async boom") }
      local caught = pcall(func(){ return await failing() })
      return caught[1].message
    })
    assert(str.index_of(r, "async boom") >= 0, r)
  }
  t.test("keywords stay usable as fields"){
    local o = {async: 1, await: 2}
    assert(o.async + o.await == 3)
  }
}
