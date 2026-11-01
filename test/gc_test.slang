local t = require("slang/test")
local time = require("slang/time")
local math = require("slang/math")

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
