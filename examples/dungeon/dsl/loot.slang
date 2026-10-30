// Loot tables.
//
//   loot goblin {
//     50% coins(1, 3)
//     20% potion
//     5% sword
//   }
//
// One roll picks at most one entry (the remainder up to 100% drops nothing),
// so the chances of a table may not add up to more than 100; that is checked
// while compiling. Arguments are ordinary expressions and are handed to the
// item when it drops. Expands to require("engine/loot").define("goblin", {...});
// roll with loot.roll("goblin") -> {item, args} or null.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local util = require("dsl/util")

local entry = peg.seq(
  util.number(), g:token("%"), g:rule("identifier"),
  util.args_of(g:rule("expr"))
)
  :map(func(r){
    return {chance: r[0], item: r[2].value, args: r[3]}
  })

g:extension_statement(
  "loot",
  peg.seq(
    g:keyword("loot"), g:rule("identifier"), g:token("{"), entry:star(),
    g:token("}")
  ),
  func(r){
    local token = r[0]
    local name = r[1].value
    local total = 0
    local nodes = {}
    for(let local e in values(r[3])){
      if(e.chance <= 0){
        g:error_at(
          token, "loot ", name, ": ", e.item, " has a chance of ", e.chance, "%"
        )
      }
      total = total + e.chance
      append(nodes, util.table_node({
        chance: util.literal(e.chance),
        item: util.string_node(e.item),
        args: util.list_node(e.args),
      }))
    }
    if(total > 100){
      g:error_at(
        token, "loot ", name, ": the chances add up to ", total,
        "%, more than 100%"
      )
    }
    return {
      token: token,
      ast: util.define("engine/loot", name, util.list_node(nodes)),
    }
  }
)

return {}
