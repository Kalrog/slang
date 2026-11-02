local t = require("slang/test")
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local params = require("params")
local patches = require("patches")
local engine = require("engine")

// The premade patches: every one names real controls and positions, and
// sounds when a key is held.

t.group("patches"){
  t.test("every patch resolves to a value for every control"){
    assert(len(patches.list) > 1)
    for(local k = 0; k < len(patches.list); k = k + 1){
      local vs = patches.values(k)
      assert(len(vs) == params.count, patches.list[k].name)
    }
    // the first is the panel's defaults, a label becomes its position
    assert(patches.values(0)[params.index.cutoff] == params.list[params.index.cutoff].default)
    local fat = null
    for(local k = 0; k < len(patches.list); k = k + 1){
      if(patches.list[k].name == "Fat Bass"){
        fat = patches.values(k)
      }
    }
    assert(fat[params.index.range1] == 2.0, "16' is position 2")
  }
  t.test("every patch sounds with a key held, and stays in range"){
    local out = buffer.new("float", 128)
    for(local k = 0; k < len(patches.list); k = k + 1){
      local p = buffer.new("double", params.count)
      local vs = patches.values(k)
      for(local i = 0; i < params.count; i = i + 1){
        p[i] = vs[i]
      }
      local events = isolate.channel()
      local block = engine.new(p, events, null, 48000)
      events:send({on: 48})
      local peak = 0.0
      // a quarter second: the slowest attack is well on its way
      for(local b = 0; b < 94; b = b + 1){
        block(out, 128)
        for(local i = 0; i < 128; i = i + 1){
          local v = out[i]
          assert(v == v, concat(patches.list[k].name, ": finite"))
          if(v > peak){
            peak = v
          } else if(-v > peak){
            peak = -v
          }
        }
      }
      local name = patches.list[k].name
      assert(peak > 0.005, concat(name, ": sounds (peak ", peak, ")"))
      assert(peak <= 1.0, concat(name, ": in range (peak ", peak, ")"))
    }
  }
}
