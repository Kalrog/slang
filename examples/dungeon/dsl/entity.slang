// The entity DSL: declares entity types with default fields and methods.
//
//   entity Monster {
//     hp: 3, solid: true,
//     hurt: func(self, amount){ self.hp = self.hp - amount },
//   }
//   entity Goblin extends Monster { hp: 2, sprite: "goblin" }
//
// expands to require("engine/entities").define("Goblin", "Monster", {...}).
// Afterwards entities.Goblin(x, y) constructs an instance whose fields fall
// back to the defaults (and to the base type's), type(instance) == "Goblin",
// and patterns like 'Goblin{hp: local hp} match it.
//
// The declared names are also kept at compile time, so that the level DSL
// can check its legends against them.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local util = require("dsl/util")

local declared = util.registry("entities")
local m = {declared: declared}

g:extension_statement("entity",
  peg.seq(
    g:keyword("entity"),
    g:rule("identifier"),
    peg.seq(g:token("extends"), g:rule("identifier")):pick(1):optional(),
    g:rule("table_literal")
  ),
  func(r){
    local token = r[0]
    local name = r[1].value
    local base = null
    if(r[2] != null){
      base = r[2].value
      if(declared[base] == null){
        g:error_at(token, "entity ", name, ": unknown base entity ", base)
      }
    }
    local fields = r[3]
    local names = {}
    for(let local field in values(fields.fields)){
      if(field.key == null or field.key.type != "String"){
        g:error_at(token, "entity ", name, ": every field needs a name")
      }
      append(names, field.key.value)
    }
    declared[name] = {base: base, fields: names}
    local base_node = util.literal(base)
    return {
      token: token,
      ast: +{stat: require("engine/entities").define(-{util.string_node(name)}, -{base_node}, -{fields})},
    }
  }
)

// is_declared(name) -> whether an entity type of that name was declared so far
func m.is_declared(name){
  return declared[name] != null
}

return m
