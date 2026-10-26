// The tile registry: tiles.NAME = {name, solid, sprite, ...}.
local m = {}

tiles = tiles or {}

func m.define(name, fields){
  fields.name = name
  tiles[name] = fields
  return fields
}

return m
