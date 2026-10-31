// maps: glyphs, object names and orientation, and the checks
extension "dsl/map"
local t = require("slang/test")
local grid = require("game/grid")

map sample {
  ########
  #S.D.$.#
  #.###.^#
  #P# #E##
}

local func broken(text){
  local r = pcall(grid.parse_text, text)
  assert(r[0] == "err", "the map should be refused")
  return r[1].message
}

t.group("grid"){
  t.test("the DSL parses while compiling, objects are named in reading order"){
    assert(sample.w == 8 and sample.h == 4)
    assert(sample.start.x == 1 and sample.start.z == 1)
    assert(sample.dossier.x == 5 and sample.exit.z == 3)
    local names = {}
    for(let local o in values(sample.objects)){
      append(names, o.name)
    }
    assert(names == {"door1", "cam1", "port1"}, string(names))
  }
  t.test(
    "doors take their axis from the walls, cameras and ports their facing",
  ){
    assert(sample.objects[0].axis == "z")
    assert(sample.objects[1].dir == "north")
    // the outside counts as wall: the port hangs on the map's edge
    assert(sample.objects[2].dir == "north")
  }
  t.test("the start looks down the longest open line"){
    assert(sample.start.yaw == grid.dirs.east.yaw)
  }
  t.test("broken maps say why"){
    assert(require("slang/string").index_of(
      broken("####\n#S$#\n####"),
      "no exit",
    ) >= 0)
    assert(require("slang/string").index_of(
      broken("#######\n#S.D$E#\n#.....#\n#######"),
      "door",
    ) >= 0)
    assert(require("slang/string").index_of(
      broken("#####\n#S$E#\n#.x.#\n#####"),
      "\"x\"",
    ) >= 0)
    assert(require("slang/string").index_of(
      broken("#####\n#S$E#\n#.>.#\n#####"),
      "wall behind",
    ) >= 0)
  }
  t.test("a broken map in the DSL is a compile error on its row"){
    local r = pcall(
      compile,
      "extension \"dsl/map\"\nmap bad {\n  ####\n  #S$#\n  #E?#\n  ####\n}\n",
      "bad_map",
    )
    assert(r[0] == "err")
    assert(
      require("slang/string").index_of(r[1].message, "row 3 column 3") >= 0,
      r[1].message,
    )
    assert(r[1].location.line == 5, string(r[1].location.line))
  }
}
