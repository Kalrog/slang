extension "dsl/entity"
extension "dsl/level"
local t = require("slang/test")
local str = require("slang/string")

entity Player { hp: 5 }
entity LevelTestGoblin { hp: 2 }
tile wall { solid: true }
tile floor { }
tile stairs { exit: true }

legend lt { "#": wall, ".": floor, "@": Player, "g": LevelTestGoblin, ">": stairs }

level lt_one lt {
  #####
  #@.g>
  #####
}

t.group("level DSL"){
  t.test("maps become tile grids and spawn lists"){
    local l = levels.lt_one
    assert(l.w == 5 and l.h == 3, "size")
    assert(l.tiles[0][0] == "wall" and l.tiles[1][1] == "floor" and l.tiles[1][4] == "stairs", "tiles")
    assert(l.tiles[1][3] == "floor", "entities stand on floor")
    assert(len(l.spawns) == 2, "two spawns")
    assert(let {type: "Player", x: 1, y: 1} = l.spawns[0], "player spawn")
    assert(let {type: "LevelTestGoblin", x: 3, y: 1} = l.spawns[1], "goblin spawn")
    assert(levels.order[len(levels.order) - 1] == "lt_one", "registered in order")
  }
  t.test("unknown characters are compile errors on the right line"){
    local r = pcall(compile, """level bad lt {
  ###
  #@?
  ###
}""", "unknown glyph")
    assert(r[0] == "err" and str.index_of(r[1].message, "\"?\" is not in the legend") >= 0, r[1].message)
    assert(r[1].location.line == 3, concat("line ", r[1].location.line))
  }
  t.test("a level needs exactly one player"){
    local r = pcall(compile, "level bad lt {\n ###\n ###\n}", "no player")
    assert(r[0] == "err" and str.index_of(r[1].message, "exactly one Player") >= 0, r[1].message)
    r = pcall(compile, "level bad lt {\n #@@\n}", "two players")
    assert(r[0] == "err" and str.index_of(r[1].message, "has 2") >= 0, r[1].message)
  }
  t.test("legends are checked against declared tiles and entities"){
    local r = pcall(compile, "legend bad { \"x\": Dragon }", "bad legend")
    assert(r[0] == "err" and str.index_of(r[1].message, "neither a declared tile nor a declared entity") >= 0, r[1].message)
    r = pcall(compile, "legend bad { \"xx\": wall }", "bad key")
    assert(r[0] == "err" and str.index_of(r[1].message, "single characters") >= 0, r[1].message)
  }
  t.test("ragged maps are compile errors"){
    local r = pcall(compile, "level bad lt {\n ###\n #@\n}", "ragged")
    assert(r[0] == "err" and str.index_of(r[1].message, "row 2") >= 0, r[1].message)
  }
}
