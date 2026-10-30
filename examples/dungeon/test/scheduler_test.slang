extension "dsl/script"
local t = require("slang/test")
local scheduler = require("engine/scheduler")

t.group("script DSL and scheduler"){
  t.test("wait suspends a task for a while"){
    scheduler.clear()
    local log = {}
    scheduler.start(func(){
      append(log, "a")
      wait 0.5
      append(log, "b")
      wait 0.25
      append(log, "c")
    })
    assert(len(log) == 1, "ran until the first wait")
    scheduler.update(0.3)
    assert(len(log) == 1, "still waiting")
    scheduler.update(0.3)
    assert(len(log) == 2, "resumed after 0.5s")
    scheduler.update(0.3)
    assert(len(log) == 3 and log[2] == "c", "finished")
    assert(scheduler.count() == 0, "task is gone")
  }
  t.test("wait for an event"){
    scheduler.clear()
    local log = {}
    scheduler.start(func(name){
      wait for "door_opened"
      append(log, concat(name, " saw the door open"))
    }, "guard")
    scheduler.update(1)
    assert(len(log) == 0, "waits for the event, not time")
    scheduler.signal("other")
    assert(len(log) == 0, "other events do not wake it")
    scheduler.signal("door_opened")
    assert(
      log[0] == "guard saw the door open",
      "woken with its arguments intact"
    )
  }
}
