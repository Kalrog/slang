// Event handlers by pattern.
//
//   on {kind: "picked_up", item: local item} {
//     hud.say(concat("You picked up ", item))
//   }
//
// expands to require("engine/events").listen(func(event){ if(let PATTERN = event){ ... } }).
// Inside the body the whole event is available as `event`. Events are plain
// tables sent with events.emit({kind: "picked_up", item: "key"}).
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()
local util = require("dsl/util")

g:statement("on",
  peg.seq(g:keyword("on"), g:rule("slang_pattern"), g:rule("block")):map(func(r){
    local condition = {type: "Let", pattern: r[1], right: util.id("event")}
    local handler = {
      type: "Function",
      params: {util.id("event")},
      body: {type: "Block", statements: {{type: "If", condition: condition, thenBranch: r[2]}}},
    }
    return {token: r[0], ast: +{stat: require("engine/events").listen(-{handler})}}
  })
)

return {}
