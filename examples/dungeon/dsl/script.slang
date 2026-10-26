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
local p = require("slang/parser")

p.add_statement("wait",
  p.seq(
    p.keyword("wait"),
    p.choice(
      p.seq(p.token("for"), p.expr()):map(func(r){ return {event: r[1]} }),
      p.expr():map(func(e){ return {seconds: e} })
    )
  ):map(func(r){
    local w = r[1]
    if(w.event != null){
      return {token: r[0], ast: +{stat: require("engine/scheduler").wait_for(-{w.event})}}
    }
    return {token: r[0], ast: +{stat: require("engine/scheduler").wait(-{w.seconds})}}
  })
)

return {}
