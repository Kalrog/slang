extension "dsl/entity"
local t = require("slang/test")
local str = require("slang/string")
local entities_api = require("engine/entities")

// a snippet compiled at run time is a unit of its own: it loads the DSL itself
local func snippet(source){
  return concat("extension \"dsl/entity\"\n", source)
}

entity TestMonster {hp: 3, solid: true, hurt: func(self, amount){ self.hp = self.hp - amount }}
entity TestGoblin extends TestMonster {hp: 2, sprite: "goblin"}

t.group("entity DSL"){
  t.test("instances fall back to the declared defaults"){
    local g = entities.TestGoblin(3, 4)
    assert(g.x == 3 and g.y == 4, "position")
    assert(g.hp == 2, "own default")
    assert(g.solid == true, "inherited default")
    g:hurt(1)
    assert(g.hp == 1, "method from the base type")
    assert(entities.TestGoblin.hp == 2, "the defaults are untouched")
    assert(entities.TestGoblin(0, 0, {hp: 10}).hp == 10, "overrides")
  }
  t.test("types and patterns"){
    local g = entities.TestGoblin(0, 0)
    assert(type(g) == "TestGoblin", "type()")
    assert(let 'TestGoblin{hp: 2} = g, "pattern with type")
    assert(entities_api.is_a(g, "TestMonster"), "is_a base")
    assert(not entities_api.is_a(g, "TestGoblin2"), "is_a other")
  }
  t.test("unknown base types are compile errors"){
    local r = pcall(
      compile, snippet("entity Nope extends Nothing { }"), "bad base"
    )
    assert(
      r[0] == "err" and
        str.index_of(r[1].message, "unknown base entity Nothing") >= 0,
      r[1].message
    )
  }
  t.test("fields must be named"){
    local r = pcall(compile, snippet("entity Nope { 1, 2 }"), "unnamed")
    assert(
      r[0] == "err" and str.index_of(r[1].message, "needs a name") >= 0,
      r[1].message
    )
  }
}
