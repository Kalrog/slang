extension "dsl/machine"
local t = require("slang/test")
local str = require("slang/string")
local machines_api = require("engine/machines")

// a snippet compiled at run time is a unit of its own: it loads the DSL itself
local func snippet(source){
  return concat("extension \"dsl/machine\"\n", source)
}

machine test_brain {
  state idle {
    enter { self.log = concat(self.log, "+idle ") }
    update(dt) {
      self.ticks = self.ticks + 1
      if(self.ticks >= 2){ goto chase }
    }
    exit { self.log = concat(self.log, "-idle ") }
  }
  state chase {
    enter { self.log = concat(self.log, "+chase ") }
    update(dt) {
      if(self.ticks > 100){ goto idle }
    }
  }
}

t.group("machine DSL"){
  t.test("states, hooks and goto"){
    local e = {log: "", ticks: 0}
    local spec = machines.test_brain
    assert(spec.initial == "idle", "first state is the initial one")
    machines_api.run(spec, e, 0.1)
    assert(e.state == "idle" and e.log == "+idle ", e.log)
    machines_api.run(spec, e, 0.1)
    assert(e.state == "chase", "switched by goto")
    assert(e.log == "+idle -idle +chase ", e.log)
    machines_api.run(spec, e, 0.1)
    assert(e.state == "chase", "stays")
  }
  t.test("goto to an unknown state is a compile error"){
    local r = pcall(compile, snippet("""machine bad {
  state a { update(dt) { goto b } }
}"""), "bad goto")
    assert(r[0] == "err" and str.index_of(r[1].message, "unknown state b") >= 0, r[1].message)
    assert(r[1].location.line == 2, concat("line ", r[1].location.line))
  }
  t.test("duplicate states and hooks are compile errors"){
    local r = pcall(compile, snippet("machine bad { state a { } state a { } }"), "dup state")
    assert(r[0] == "err" and str.index_of(r[1].message, "declared twice") >= 0, r[1].message)
    r = pcall(compile, snippet("machine bad { state a { enter { } enter { } } }"), "dup hook")
    assert(r[0] == "err" and str.index_of(r[1].message, "two enter hooks") >= 0, r[1].message)
  }
  t.test("goto outside a machine fails at run time"){
    local r = pcall(compile(snippet("goto somewhere"), "stray goto"))
    assert(r[0] == "err" and str.index_of(r[1].message, "inside a machine") >= 0, r[1].message)
  }
}
