// The sprite registry. `sprite NAME {...}` declarations (dsl/sprite) expand to
// require("engine/sprites").define(NAME, {w, h, pixels}); game code reads
// sprites.NAME.
local m = {}

sprites = sprites or {}

func m.define(name, data){
  sprites[name] = data
  return data
}

return m
