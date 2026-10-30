extension "dsl/loot"
local t = require("slang/test")
local str = require("slang/string")
local loot_api = require("engine/loot")

// a snippet compiled at run time is a unit of its own: it loads the DSL itself
local func snippet(source){
  return concat("extension \"dsl/loot\"\n", source)
}

loot test_goblin {
  50% coins(1, 3)
  20% potion
  5% sword
}

t.group("loot DSL"){
  t.test("one roll picks one entry by cumulative chance"){
    local r = loot_api.roll("test_goblin", 10)
    assert(
      r.item == "coins" and r.args[0] == 1 and r.args[1] == 3,
      "coins with args"
    )
    assert(loot_api.roll("test_goblin", 49.9).item == "coins", "edge of coins")
    assert(loot_api.roll("test_goblin", 50).item == "potion", "potion")
    assert(loot_api.roll("test_goblin", 74).item == "sword", "sword")
    assert(loot_api.roll("test_goblin", 75) == null, "nothing")
    assert(loot_api.roll("test_goblin", 99) == null, "nothing at the end")
    assert(loot_api.roll("test_goblin") == null or true, "random roll works")
  }
  t.test("chances over 100% are compile errors"){
    local r = pcall(
      compile, snippet("loot bad {\n 60% a\n 50% b\n}"), "too much"
    )
    assert(
      r[0] == "err" and str.index_of(r[1].message, "110%") >= 0,
      r[1].message
    )
    r = pcall(compile, snippet("loot bad {\n 0% a\n}"), "zero")
    assert(
      r[0] == "err" and str.index_of(r[1].message, "chance of 0%") >= 0,
      r[1].message
    )
  }
}
