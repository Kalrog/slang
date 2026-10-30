// Multi-frame scripts: statements that suspend the running task.
//
//   scheduler.start(func(){
//     door:open()
//     wait 0.5
//     wait for "player_moved"
//     door:close()
//   })
//
// `wait SECONDS` and `wait for EVENT_NAME` expand to calls of
// require("engine/scheduler") that yield from the task's coroutine; the
// scheduler resumes it when the time has passed or the event was emitted.
local peg = require("slang/peg")
local g = require("slang/compiler").grammar()

g:statement(
  "wait",
  peg.seq(
    g:keyword("wait"),
    peg.choice(peg.seq(g:token("for"), g:rule("expr")):map(func(r){
      return {event: r[1]}
    }), g:rule("expr"):map(func(e){ return {seconds: e} }))
  )
    :map(func(r){
      local w = r[1]
      if(w.event != null){
        return {
          token: r[0],
          ast: +{stat: require("engine/scheduler").wait_for(-{w.event})},
        }
      }
      return {
        token: r[0],
        ast: +{stat: require("engine/scheduler").wait(-{w.seconds})},
      }
    })
)

return {}
