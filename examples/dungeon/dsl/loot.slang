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
local p = require("slang/parser")
local util = require("dsl/util")

local entry = p.seq(util.number(), p.token("%"), p.identifier(), util.args_of(p.expr())):map(func(r){
  return {chance: r[0], item: r[2].value, args: r[3]}
})

p.add_extension_statement("loot",
  p.seq(p.keyword("loot"), p.identifier(), p.token("{"), entry:star(), p.token("}")),
  func(r){
    local token = r[0]
    local name = r[1].value
    local total = 0
    local nodes = {}
    for(let local e in values(r[3])){
      if(e.chance <= 0){
        p.error_at(token, "loot ", name, ": ", e.item, " has a chance of ", e.chance, "%")
      }
      total = total + e.chance
      append(nodes, util.table_node({
        chance: util.literal(e.chance),
        item: util.string_node(e.item),
        args: util.list_node(e.args),
      }))
    }
    if(total > 100){
      p.error_at(token, "loot ", name, ": the chances add up to ", total, "%, more than 100%")
    }
    return {token: token, ast: util.define("engine/loot", name, util.list_node(nodes))}
  }
)

return {}
