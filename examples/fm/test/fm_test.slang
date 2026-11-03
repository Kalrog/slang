local t = require("slang/test")
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local time = require("slang/time")
local algorithms = require("algorithms")
local patch = require("patch")
local engine = require("engine")

// The synth without a window or an audio device: algorithms, patches, and
// the engine rendering every patch of the bank.

// an engine, its event channel and status
local func setup(){
  local controls = buffer.new("double", engine.CONTROLS)
  controls[engine.VOLUME] = 0.7
  local events = isolate.channel()
  local status = buffer.new("double", 4)
  return {
    controls: controls, events: events, status: status,
    block: engine.new(controls, events, null, 48000, status),
    out: buffer.new("float", 64),
  }
}

// renders blocks: {peak, finite}
local func render(s, blocks){
  local peak = 0.0
  local finite = true
  for(local b = 0; b < blocks; b = b + 1){
    s.block(s.out, 64)
    for(local i = 0; i < 64; i = i + 1){
      local v = s.out[i]
      if(v != v){
        finite = false
      }
      if(v > peak){
        peak = v
      } else if(-v > peak){
        peak = -v
      }
    }
  }
  return {peak: peak, finite: finite}
}

t.group("fm"){
  t.test("algorithms: 32, every operator below its modulators, carriers"){
    assert(algorithms.count == 32)
    for(local n = 1; n <= 32; n = n + 1){
      local a = algorithms.get(n)
      for(local k = 1; k <= 6; k = k + 1){
        for(let local m in values(a.mods[k])){
          assert(m > k, concat("algorithm ", n, ": ", m, " modulates ", k))
        }
      }
      assert(a.fb_from != null and len(a.carriers) > 0)
    }
    assert(string(algorithms.get(1).carriers) == string({1, 3}))
    assert(len(algorithms.get(32).carriers) == 6 and len(algorithms.get(16).carriers) == 1)
    assert(algorithms.get(4).fb_from == 4 and algorithms.get(4).fb_to == 6)
  }
  t.test("patches: ratios and fixed frequencies written compactly"){
    local o = patch.op({ratio: 2.76})
    assert(o.coarse == 2 and o.fine == 38 and patch.frequency_text(o) == "2.76")
    o = patch.op({ratio: 0.5})
    assert(o.coarse == 0 and o.fine == 0 and patch.ratio(o) == 0.5)
    o = patch.op({fixed: 440})
    // (fine steps are coarse: 440 Hz is 437)
    assert(o.mode == 1 and o.coarse == 2 and patch.frequency_text(o) == "437Hz", patch.frequency_text(o))
    local msg = pcall(func(){ patch.voice({name: "X", feedback: 9}) })[1].message
    assert(require("slang/string").contains(msg, "feedback is 9"), msg)
  }
  t.test("every patch of the bank sounds, stays in range, and ends"){
    local bank = require("patches")
    assert(len(bank) == 32)
    local s = setup()
    for(let local p in values(bank)){
      s.events:send({panic: true})
      s.events:send({patch: p})
      s.events:send({on: 60, vel: 100})
      s.events:send({on: 67, vel: 70})
      // a quarter of a second held, then let go
      local r = render(s, 190)
      assert(r.finite, concat(p.name, ": finite"))
      // (slow attacks are only starting)
      assert(r.peak > 0.002, concat(p.name, ": sounds (peak ", r.peak, ")"))
      assert(r.peak < 1.0, concat(p.name, ": limited"))
      assert(s.status[0] == 2, concat(p.name, ": two voices"))
      s.events:send({off: 60})
      s.events:send({off: 67})
      // released voices end (the slowest releases take a few seconds)
      for(local k = 0; k < 90 and s.status[0] > 0; k = k + 1){
        render(s, 50)
      }
      assert(s.status[0] == 0, concat(p.name, ": voices end after release"))
    }
  }
  t.test("voices: the same note reuses its voice, the seventeenth steals"){
    local s = setup()
    s.events:send({patch: require("patches")[5]})
    for(local n = 0; n < 16; n = n + 1){
      s.events:send({on: 40 + n})
    }
    render(s, 2)
    assert(s.status[0] == 16)
    s.events:send({on: 40})
    s.events:send({on: 80})
    render(s, 2)
    assert(s.status[0] == 16)
  }
  t.test("an edit reaches a held note"){
    local s = setup()
    local p = patch.copy(require("patches")[5])
    s.events:send({patch: p})
    s.events:send({on: 60})
    local before = render(s, 40).peak
    // every operator off: silence while the key is still down
    for(let local o in values(p.ops)){
      o.on = 0
    }
    s.events:send({patch: p})
    render(s, 4)
    local after = render(s, 20).peak
    assert(before > 0.05 and after < 0.0001, concat("", before, " ", after))
  }
  t.test("cost of sixteen voices (printed)"){
    local s = setup()
    s.events:send({patch: require("patches")[0]})
    for(local n = 0; n < 16; n = n + 1){
      s.events:send({on: 48 + n * 2, vel: 100})
    }
    local t0 = time.clock()
    render(s, 750)
    local ms = time.clock() - t0
    print("    sixteen voices: ", to_int(ms), " ms per second of sound\n")
  }
}
