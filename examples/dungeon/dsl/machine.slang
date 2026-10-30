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
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local util = require("dsl/util")

local m = {}

// goto NAME  ->  return __goto("NAME")  (rewritten by the enclosing machine)
g:statement(
  "goto",
  peg.seq(g:keyword("goto"), g:rule("identifier")):map(func(r){
    return {
      token: r[0],
      ast: +{stat: return __goto(-{util.string_node(r[1].value)})},
    }
  })
)

local func is_goto(node){
  return node.type == "Return" and node.value != null and
    node.value.type == "Call" and node.value.function.type == "Identifier" and
    node.value.function.value == "__goto"
}

local hook = peg.choice(
  peg.seq(g:token("enter"), g:rule("block")):map(func(r){
    return {hook: "enter", params: {util.id("self")}, body: r[1]}
  }),
  peg.seq(g:token("exit"), g:rule("block")):map(func(r){
    return {hook: "exit", params: {util.id("self")}, body: r[1]}
  }),
  peg.seq(
    g:token("update"), g:token("("), g:rule("identifier"), g:token(")"),
    g:rule("block")
  )
    :map(func(r){
      return {hook: "update", params: {util.id("self"), r[2]}, body: r[4]}
    })
)

local state = peg.seq(
  g:token("state"), g:rule("identifier"), g:token("{"), hook:star(),
  g:token("}")
)
  :map(func(r){
    return {name: r[1].value, hooks: r[3]}
  })

g:extension_statement(
  "machine",
  peg.seq(
    g:keyword("machine"), g:rule("identifier"), g:token("{"), state:star(),
    g:token("}")
  ),
  func(r){
    local token = r[0]
    local name = r[1].value
    local states = r[3]
    if(len(states) == 0){
      g:error_at(
        token, "machine ", name, ": a machine needs at least one state"
      )
    }
    local names = {}
    for(let local s in values(states)){
      if(names[s.name] != null){
        g:error_at(
          token, "machine ", name, ": state ", s.name, " is declared twice"
        )
      }
      names[s.name] = true
    }
    local state_fields = {}
    for(let local s in values(states)){
      local hooks = {}
      for(let local h in values(s.hooks)){
        if(hooks[h.hook] != null){
          g:error_at(
            token, "machine ", name, ": state ", s.name, " has two ", h.hook,
            " hooks"
          )
        }
        util.walk(h.body, func(node){
          if(is_goto(node)){
            local target = node.value.args[0].value
            if(names[target] == null){
              g:error_at(
                token, "machine ", name, ": state ", s.name,
                " jumps to unknown state ", target
              )
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
