// Dialogue trees that run as coroutines.
//
//   dialogue elder {
//     say "Welcome, traveler."
//     choice {
//       "Who are you?" => { say "The elder of this cave." }
//       "Bye" => { }
//     }
//     if(flags.has_key){ say "I see you found the key." }
//   }
//
// The body is ordinary slang plus two statements: `say TEXT` shows a line and
// waits for the player, `choice { LABEL => BLOCK ... }` shows options and runs
// the chosen block. Both yield from the dialogue's coroutine, so the game
// loop keeps running while the text box is open. Expands to
//   require("engine/dialogue").define("elder", func(){ ... })
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local util = require("dsl/util")

g:statement("say", peg.seq(g:keyword("say"), g:rule("expr")):map(func(r){
  return {token: r[0], ast: +{stat: require("engine/dialogue").say(-{r[1]})}}
}))

local option = peg.seq(g:rule("expr"), g:token("=>"), g:rule("block"))
  :map(func(r){
    return {label: r[0], body: r[2]}
  })

g:statement(
  "choice",
  peg.seq(g:keyword("choice"), g:token("{"), option:star(), g:token("}"))
    :map(func(r){
      local token = r[0]
      local options = r[2]
      if(len(options) == 0){
        g:error_at(token, "a choice needs at least one option")
      }
      local labels = {}
      for(let local o in values(options)){
        append(labels, o.label)
      }
      local chosen = g:uniq_id()
      local declaration = {
        type: "Declaration", is_local: true, left: chosen,
        right: +{require("engine/dialogue").choose(-{util.list_node(labels)})},
      }
      // if(chosen == 0) body0 else if(chosen == 1) body1 ...
      local chain = null
      for(local i = len(options) - 1; i >= 0; i = i - 1){
        local test = {
          type: "BinOp", op: "==", left: chosen, right: util.int_node(i),
        }
        chain = {
          type: "If", condition: test, thenBranch: options[i].body,
          elseBranch: chain,
        }
      }
      return {
        token: token,
        ast: {type: "Block", statements: {declaration, chain}},
      }
    })
)

g:extension_statement(
  "dialogue",
  peg.seq(g:keyword("dialogue"), g:rule("identifier"), g:rule("block")),
  func(r){
    local f = {type: "Function", params: {}, body: r[2]}
    return {token: r[0], ast: util.define("engine/dialogue", r[1].value, f)}
  }
)

return {}
