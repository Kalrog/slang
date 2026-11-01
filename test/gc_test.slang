local t = require("slang/test")
local time = require("slang/time")

t.group("collector"){
  // interned strings the collector removed used to leave tombstones that
  // the intern table counted as free, so after enough distinct short
  // strings every lookup of a new one probed the whole table
  t.test("distinct short strings stay flat per string"){
    local n = 60000
    local func batch(from){
      local t0 = time.clock()
      local s = null
      for(local i = from; i < from + n; i = i + 1){
        s = concat("item", i)
      }
      return time.clock() - t0
    }
    local first = batch(0)
    local last = null
    for(local k = 1; k < 4; k = k + 1){
      last = batch(k * n)
    }
    // the cliff was a factor of 100 and more; the noise a factor of 2
    assert(last < first * 5, concat("last batch ", last, " vs first ", first))
  }
}
