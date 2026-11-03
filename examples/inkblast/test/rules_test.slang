// the rules on small, hand-made arenas
local t = require("slang/test")
local rules = require("game/rules")

// a world without crates, so that what a test puts there is all there is
local func empty_world(){
  local w = rules.new_world(1)
  for(local i = 0; i < len(w.cells); i = i + 1){
    if(w.cells[i] == rules.CRATE){
      w.cells[i] = rules.FLOOR
    }
  }
  return w
}

local func steps(w, ms){
  for(local n = 0; n * rules.TICK < ms; n = n + 1){
    rules.step(w)
  }
}

local func at(w, x, y){
  return w.cells[rules.index(x, y)]
}

t.group("rules"){
  t.test("an arena has walls, pillars, crates and free corners"){
    local w = rules.new_world(7)
    assert(at(w, 0, 0) == rules.PILLAR and at(w, 2, 2) == rules.PILLAR)
    for(let local s in values(rules.SPAWNS)){
      assert(at(w, s[0], s[1]) == rules.FLOOR, string(s))
    }
    local crates = 0
    for(let local c in values(w.cells)){
      if(c == rules.CRATE){
        crates = crates + 1
      }
    }
    assert(crates > 40, string(crates))
    assert(string(rules.new_world(7).cells) == string(w.cells), "a seed makes the same arena")
  }
  t.test("players walk cell to cell, not through pillars"){
    local w = empty_world()
    local p = rules.add_player(w, 0, "a")
    p.input = 2
    steps(w, 3000)
    assert(p.x == 13 and p.y == 1 and not p.moving, concat(string(p.x), ",", string(p.y)))
    p.input = 4
    steps(w, 200)
    p.input = 0
    steps(w, 300)
    assert(p.x == 12 and not p.moving, string(p.x))
    // (12, 2) is a pillar
    p.input = 3
    steps(w, 500)
    assert(p.x == 12 and p.y == 1, concat(string(p.x), ",", string(p.y)))
  }
  t.test("a blast stops at pillars, breaks the first crate, paints the floor"){
    local w = empty_world()
    w.cells[rules.index(1, 3)] = rules.CRATE
    w.cells[rules.index(1, 4)] = rules.CRATE
    local p = rules.add_player(w, 0, "a")
    assert(rules.drop(w, 0))
    assert(not rules.drop(w, 0), "one charge per cell")
    p.input = 2
    steps(w, 2300)
    assert(len(w.charges) == 0 and len(w.blasts) == 1)
    assert(at(w, 1, 3) != rules.CRATE, "the first crate breaks")
    assert(at(w, 1, 4) == rules.CRATE, "the one behind it stands")
    assert(w.paint[rules.index(1, 1)] == 1 and w.paint[rules.index(3, 1)] == 1)
    assert(w.paint[rules.index(4, 1)] == 0, "reach 2")
    assert(p.score >= 5, string(p.score))
  }
  t.test("a blast sets off the charges it reaches"){
    local w = empty_world()
    rules.add_player(w, 0, "a")
    rules.add_player(w, 1, "b")
    rules.drop(w, 0)
    local b = w.players[1]
    b.x = 3
    b.y = 1
    rules.drop(w, 1)
    w.charges[1].at = w.now + 99999
    b.x = 13
    b.y = 9
    steps(w, 2300)
    assert(len(w.charges) == 0, "the second went off with the first")
    assert(w.paint[rules.index(5, 1)] == 2, "and painted in its owner's colour")
  }
  t.test("a player in a blast is out, then back at their corner"){
    local w = empty_world()
    local a = rules.add_player(w, 0, "a")
    local b = rules.add_player(w, 1, "b")
    b.x = 2
    b.y = 1
    b.safe_until = 0
    rules.drop(w, 0)
    a.input = 3
    steps(w, 2300)
    assert(not b.alive and a.kos == 1, string(a.kos))
    steps(w, 3100)
    assert(b.alive and b.x == 13 and b.y == 9)
    assert(a.alive, "a walked away")
  }
  t.test("a pot splashes ink, the round ends with a winner"){
    local w = empty_world()
    local p = rules.add_player(w, 0, "a")
    rules.add_player(w, 1, "b")
    w.cells[rules.index(2, 1)] = rules.POT
    p.input = 2
    steps(w, 250)
    assert(at(w, 2, 1) == rules.FLOOR and w.paint[rules.index(3, 1)] == 1)
    w.left = rules.TICK
    rules.step(w)
    assert(w.phase == "over" and w.winner == 0)
  }
  t.test("a snapshot carries the arena as bytes"){
    local w = rules.new_world(3)
    rules.add_player(w, 0, "a")
    local s = rules.snapshot(w)
    assert(len(s.cells) == rules.W * rules.H and len(s.paint) == rules.W * rules.H)
    assert(len(s.players) == 1 and s.players[0][0] == 0)
  }
}
