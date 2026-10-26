extension "dsl/events"
local t = require("slang/test")
local events = require("engine/events")

t.group("event DSL"){
  t.test("handlers run for matching events only"){
    events.clear()
    local seen = {}
    on {kind: "picked_up", item: local item} {
      append(seen, concat("got ", item))
    }
    on {kind: "died"} {
      append(seen, concat("died: ", event.who))
    }
    events.emit({kind: "picked_up", item: "key"})
    events.emit({kind: "died", who: "goblin"})
    events.emit({kind: "moved"})
    assert(len(seen) == 2, concat("two handled, ", len(seen)))
    assert(seen[0] == "got key" and seen[1] == "died: goblin", "contents")
    assert(len(events.log()) == 3, "all events are logged")
  }
}
