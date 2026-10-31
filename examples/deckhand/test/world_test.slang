// the world: walls and doors stop you, limits and rests, cameras, lasers,
// glass, the deck's view of objects
local t = require("slang/test")
local grid = require("game/grid")
local world = require("game/world")

local func make(text, objects){
  return world.new({
    name: "test",
    title: "test",
    map: grid.parse_text(text),
    objects: objects or {},
  })
}

local func walk(w, seconds, input){
  for(local i = 0; i < to_int(seconds * 60); i = i + 1){
    w:update(1 / 60, input)
  }
}

// a corridor going east: start, door, dossier, exit
local corridor = "#######\n#S.D$E#\n#######"

t.group("world"){
  t.test("a closed door stops you, an open one lets you through"){
    local w = make(corridor, {})
    w.player.yaw = 0.0
    walk(w, 1.5, {forward: 1})
    assert(
      w.player.x < 3 - world.DOOR_THICK / 2 - world.PLAYER_RADIUS + 0.01,
      string(w.player.x),
    )
    w:handle(w.objects.door1).open()
    walk(w, 2, {forward: 1})
    assert(w.has_dossier and w.state == "complete")
  }
  t.test("limits clamp and rests refuse, with a word on the deck"){
    local w = make(corridor, {door1: {limit: 2, rest: 3}})
    local door = w:handle(w.objects.door1)
    assert(door.open(10))
    assert(w.objects.door1 .close_at == 2.0)
    walk(w, 2.5, {})
    assert(not door.is_open())
    assert(not door.open(1), "resting")
    assert(require("slang/string").index_of(
      w.deck.log[len(w.deck.log) - 1].text,
      "resetting",
    ) >= 0)
    walk(w, 3, {})
    assert(door.open(1))
  }
  t.test("methods work with a dot or a colon"){
    local w = make(corridor, {})
    local door = w:handle(w.objects.door1)
    door:open(1)
    assert(w.objects.door1 .close_at == 1.0)
    assert(string(door) == "door1 (door, open)")
  }
  t.test("a door does not close on you"){
    local w = make(corridor, {})
    w:handle(w.objects.door1).open(0.5)
    walk(w, 0.5, {})
    w.player.x = 3.0
    walk(w, 1, {})
    assert(w.objects.door1 .amount >= world.DOOR_PASS)
  }
  t.test(
    "a camera sees along its cone, not through walls; glass does not hide",
  ){
    local w = make("#########\n#S.....<#\n#.#####.#\n#.%...$E#\n#########", {
      cam1: {sweep: 0, fov: 40},
    })
    local cam = w.objects.cam1
    assert(w:sees(cam, 2, 1))
    assert(not w:sees(cam, 1, 3), "behind a wall")
    assert(not w:sees(cam, 7, 3), "outside the cone")
    w = make("#########\n#S.....<#\n#.......#\n#.%...$E#\n#########", {
      cam1: {sweep: 0, fov: 120, range: 10},
    })
    assert(w:sees(w.objects.cam1, 1, 3), "through the glass")
    cam = w.objects.cam1
    cam.on = false
    assert(not w:sees(cam, 2, 1))
  }
  t.test("being seen fills the meter; long enough is the alarm"){
    local w = make("#########\n#S.....<#\n#$E######\n#########", {
      cam1: {sweep: 0},
    })
    w.player.x = 3.0
    walk(w, 0.2, {})
    assert(w.state == "playing" and w.spotted > 0.3)
    walk(w, 0.5, {})
    assert(w.state == "caught" and w.reason == "cam1 saw you")
  }
  t.test("a laser trips at once, and not when off"){
    local w = make("#######\n#S.L$E#\n#######", {})
    w:handle(w.objects.laser1).off(1)
    w.player.yaw = 0.0
    walk(w, 0.7, {forward: 1})
    assert(w.state == "playing")
    walk(w, 0.5, {forward: - 1})
    walk(w, 0.6, {})
    walk(w, 0.6, {forward: 1})
    assert(w.state == "caught" and w.reason == "you tripped laser1")
  }
  t.test("a port reaches its network and nothing else"){
    local w = make("########\n#S.P#$E#\n#...D..#\n########", {
      port1: {network: {"door1"}},
    })
    w.player.x = 3.0
    w.player.yaw = grid.dirs.north.yaw
    w:update(1 / 60, {use: true})
    assert(w.jacked == "port1")
    assert(w:type_code("door1.open()"))
    assert(w.objects.door1 .target == 1.0)
    w:type_code("port1.open()")
    assert(w.deck.log[len(w.deck.log) - 1].kind == "err")
  }
  t.test("a mission naming objects the map lacks is refused"){
    local r = pcall(make, corridor, {door9: {}})
    assert(r[0] == "err")
  }
}
