// The level DSL: tiles, legends and ASCII maps.
//
//   tile wall { solid: true, sprite: "wall" }
//   tile floor { sprite: "floor" }
//   legend main { "#": wall, ".": floor, "@": Player, "g": Goblin }
//   level one main {
//     ########
//     #@...g.#
//     ########
//   }
//
// A legend maps characters to tile names or entity names (entities must be
// declared before the legend, with dsl/entity). Entities stand on the tile
// called `floor`. Every level is checked while it is compiled: rectangular,
// only characters from its legend, exactly one Player. A level expands to
//   require("engine/levels").define("one", {w, h, tiles, spawns})
// where tiles[y][x] is a tile name and spawns is a list of {type, x, y}.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local str = require("slang/string")
local util = require("dsl/util")
local entity_dsl = require("dsl/entity")

local tiles = {}
local legends = {}
local m = {tiles: tiles, legends: legends}

// tile NAME { fields }
g:extension_statement("tile",
  peg.seq(g:keyword("tile"), g:rule("identifier"), g:rule("table_literal")),
  func(r){
    local token = r[0]
    local name = r[1].value
    for(let local field in values(r[2].fields)){
      if(field.key == null or field.key.type != "String"){
        g:error_at(token, "tile ", name, ": every field needs a name")
      }
    }
    tiles[name] = true
    return {token: token, ast: util.define("engine/tiles", name, r[2])}
  }
)

// legend NAME { "c": tile_or_entity, ... }
local legend_entry = peg.seq(util.quoted(), g:token(":"), g:rule("identifier")):map(func(r){
  return {glyph: r[0], target: r[2].value}
})

g:extension_statement("legend",
  peg.seq(
    g:keyword("legend"),
    g:rule("identifier"),
    g:token("{"),
    legend_entry:star_separated(g:token(",")):map(func(r){ return r.elements }),
    g:token(","):optional(),
    g:token("}")
  ),
  func(r){
    local token = r[0]
    local name = r[1].value
    local entries = {}
    for(let local entry in values(r[3])){
      if(len(entry.glyph) != 1){
        g:error_at(token, "legend ", name, ": keys must be single characters, like \"#\": wall")
      }
      local target = entry.target
      if(tiles[target]){
        entries[entry.glyph] = {tile: target}
      } else if(entity_dsl.is_declared(target)){
        entries[entry.glyph] = {spawn: target}
      } else {
        g:error_at(token, "legend ", name, ": \"", entry.glyph, "\" refers to ", target, ", which is neither a declared tile nor a declared entity")
      }
    }
    legends[name] = entries
    return null
  }
)

// build(rows, legend, fail) -> {w, h, tiles, spawns}
func m.build(rows, legend, fail){
  local h = len(rows.rows)
  if(h == 0){
    fail(0, "a level needs at least one row")
  }
  local w = len(rows.rows[0])
  local grid = {}
  local spawns = {}
  local players = 0
  for(local y = 0; y < h; y = y + 1){
    local row = rows.rows[y]
    if(len(row) != w){
      fail(y, "row ", y + 1, " is ", len(row), " characters wide, the first row is ", w)
    }
    local line = {}
    for(local x = 0; x < w; x = x + 1){
      local ch = str.char_at(row, x)
      local entry = legend[ch]
      if(entry == null){
        fail(y, "row ", y + 1, " column ", x + 1, ": \"", ch, "\" is not in the legend")
      }
      if(entry.tile != null){
        append(line, entry.tile)
      } else {
        if(not tiles.floor){
          fail(y, "entities stand on the tile `floor`, which is not declared")
        }
        append(line, "floor")
        append(spawns, {type: entry.spawn, x: x, y: y})
        if(entry.spawn == "Player"){
          players = players + 1
        }
      }
    }
    append(grid, line)
  }
  if(players != 1){
    fail(0, "a level needs exactly one Player, this one has ", players)
  }
  return {w: w, h: h, tiles: grid, spawns: spawns}
}

// level NAME [LEGEND] { rows }
g:extension_statement("level",
  peg.seq(g:keyword("level"), g:rule("identifier"), g:rule("identifier"):optional(), util.raw_block()),
  func(r){
    local token = r[0]
    local name = r[1].value
    local legend_name = "default"
    if(r[2] != null){
      legend_name = r[2].value
    }
    local legend = legends[legend_name]
    if(legend == null){
      g:error_at(token, "level ", name, ": unknown legend \"", legend_name, "\"")
    }
    local rows = util.rows(r[3])
    local built = m.build(rows, legend, func(row, ...message){
      util.error_at_row(rows, row, concat("level ", name, ": ", util.text(message)))
    })
    built.name = name
    return {token: token, ast: util.define("engine/levels", name, util.literal(built))}
  }
)

return m
