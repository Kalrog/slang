// The state machine DSL, for entity behaviour.
//
//   machine goblin_brain {
//     state idle {
//       enter { self.timer = 0 }
//       update(dt) {
//         if(self:sees_player()){ goto chase }
//       }
//     }
//     state chase {
//       update(dt) { ... goto idle ... }
//       exit { ... }
//     }
//   }
//
// Hooks are functions of (self) or (self, dt). `goto NAME` leaves the hook and
// switches to the named state; a goto to a state that the machine does not
// declare is a compile error. The machine expands to
//   require("engine/machines").define("goblin_brain", {initial, states})
// and is run with machines.run(machines.goblin_brain, entity, dt).
local p = require("slang/parser")
local util = require("dsl/util")

local m = {}

// goto NAME  ->  return __goto("NAME")  (rewritten by the enclosing machine)
p.add_statement("goto",
  p.seq(p.keyword("goto"), p.identifier()):map(func(r){
    return {token: r[0], ast: +{stat: return __goto(-{util.string_node(r[1].value)})}}
  })
)

local func is_goto(node){
  return node.type == "Return" and node.value != null and node.value.type == "Call"
    and node.value.function.type == "Identifier" and node.value.function.value == "__goto"
}

local hook = p.choice(
  p.seq(p.token("enter"), p.block()):map(func(r){
    return {hook: "enter", params: {util.id("self")}, body: r[1]}
  }),
  p.seq(p.token("exit"), p.block()):map(func(r){
    return {hook: "exit", params: {util.id("self")}, body: r[1]}
  }),
  p.seq(p.token("update"), p.token("("), p.identifier(), p.token(")"), p.block()):map(func(r){
    return {hook: "update", params: {util.id("self"), r[2]}, body: r[4]}
  })
)

local state = p.seq(p.token("state"), p.identifier(), p.token("{"), hook:star(), p.token("}")):map(func(r){
  return {name: r[1].value, hooks: r[3]}
})

p.add_extension_statement("machine",
  p.seq(p.keyword("machine"), p.identifier(), p.token("{"), state:star(), p.token("}")),
  func(r){
    local token = r[0]
    local name = r[1].value
    local states = r[3]
    if(len(states) == 0){
      p.error_at(token, "machine ", name, ": a machine needs at least one state")
    }
    local names = {}
    for(let local s in values(states)){
      if(names[s.name] != null){
        p.error_at(token, "machine ", name, ": state ", s.name, " is declared twice")
      }
      names[s.name] = true
    }
    local state_fields = {}
    for(let local s in values(states)){
      local hooks = {}
      for(let local h in values(s.hooks)){
        if(hooks[h.hook] != null){
          p.error_at(token, "machine ", name, ": state ", s.name, " has two ", h.hook, " hooks")
        }
        util.walk(h.body, func(node){
          if(is_goto(node)){
            local target = node.value.args[0].value
            if(names[target] == null){
              p.error_at(token, "machine ", name, ": state ", s.name, " jumps to unknown state ", target)
            }
            node.value = util.string_node(target)
          }
        })
        hooks[h.hook] = {type: "Function", params: h.params, body: h.body}
      }
      state_fields[s.name] = util.table_node(hooks)
    }
    local spec = util.table_node({
      initial: util.string_node(states[0].name),
      states: util.table_node(state_fields),
    })
    return {token: token, ast: util.define("engine/machines", name, spec)}
  }
)

return m
