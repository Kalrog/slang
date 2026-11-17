extension "kernel/syntax"
// studio/engine: the side that makes the sound. It holds the units (the
// instruments and effects of every strip), takes the instructions of the
// ring at their sample, moves the parameters the LFOs move, and mixes
// tracks into buses into the master.
//
//   local engine = require("studio/engine")
//   local e = engine.new(state)          // state: events.state(48000)
//   e.configure(layout)                  // the strips (studio/init makes it)
//   e.block(out, 128)                    // 128 stereo frames, interleaved
//
// A program does not use this module: require("studio") does, in the
// program's isolate when rendering offline and in the audio stream's when
// playing. The work per block is slang's (which unit renders into which
// buffer, the instructions, the LFOs); every sample is a kernel's.
//
// A block is rendered in segments: up to the next instruction's time, the
// instruction, and on. Per segment each track's instrument renders into the
// track's own buffers, its inserts work on them in place, and the strip
// (gain, pan, mute; ramped across the segment) adds them to where the track
// goes and to the buses it sends to; then the buses' inserts and strips,
// then the master's.
local kernel = require("kernel")
local math = require("slang/math")
local events = require("studio/events")
local param = require("studio/param")
local units = require("studio/units")

local engine = {}

engine.MAXB = 1024 // frames a segment has at most

kernel {
  func clear(l: float[], r: float[], start: int, n: int){
    for(local i = start; i < start + n; i += 1){
      l[i] = 0.0
      r[i] = 0.0
    }
  }

  // src into dst, the left gain going from l0 to l1 across the segment and
  // the right from r0 to r1
  func mix(
    dl: float[], dr: float[], sl: float[], sr: float[], start: int, n: int,
    l0: float, l1: float, r0: float, r1: float
  ){
    local dgl = (l1 - l0) / float(n)
    local dgr = (r1 - r0) / float(n)
    local gl = l0
    local gr = r0
    for(local i = start; i < start + n; i += 1){
      gl += dgl
      gr += dgr
      dl[i] += sl[i] * gl
      dr[i] += sr[i] * gr
    }
  }

  // the strip's meter: its peaks after the fader, falling by decay per
  // segment
  func meter(
    l: float[], r: float[], start: int, n: int, gl: float, gr: float,
    meters: double[], at: int, decay: float
  ){
    local pl = meters[at] * decay
    local pr = meters[at + 1] * decay
    for(local i = start; i < start + n; i += 1){
      pl = max(pl, abs(l[i]) * gl)
      pr = max(pr, abs(r[i]) * gr)
    }
    meters[at] = pl
    meters[at + 1] = pr
  }

  // the master into the stream's block (interleaved) and the scope's ring;
  // returns where the scope's next sample goes
  func deliver(
    out: float[], base: int, l: float[], r: float[], start: int, n: int,
    g0: float, g1: float, scope: float[], at: int
  ): int {
    local dg = (g1 - g0) / float(n)
    local g = g0
    local size = len(scope)
    for(local i = start; i < start + n; i += 1){
      g += dg
      local a = l[i] * g
      local b = r[i] * g
      l[i] = a
      r[i] = b
      out[(base + i) * 2] = a
      out[(base + i) * 2 + 1] = b
      scope[at] = (a + b) * 0.5
      at += 1
      if(at >= size){
        at = 0
      }
    }
    return at
  }
}

local K = events.kinds
local SHAPES = {"sine", "triangle", "ramp", "square", "random", "drift"}
engine.SHAPES = SHAPES

// new(state: State) -> Engine
// An engine over the shared buffers of events.state(). It has no strips
// until configure.
// type Engine = {block: func(out: Buffer, frames: int),
//   configure: func(layout: table), message: func(id: int, m: table),
//   take: func(), flush: func(), poll: func(commands: Channel)}
// [block]: the next frames of sound into out (interleaved stereo floats)
// [configure]: the strips, their units and the LFOs as the program's side
//   lists them; units that were there before keep their state
// [message]: something a unit takes besides parameters (a sample to play)
// [take]: the ring's instructions into the engine's own list (block does
//   it; the program's side calls it when it fills the ring offline)
// [flush]: take, and the instructions due now applied without rendering
// [poll]: configure and message as they arrive on a channel (the stream's
//   block function calls it before every block)
func engine.new(state){
  local sr = state.sample_rate * 1.0
  local vals = state.values
  local eff = state.eff
  local ring = state.ring
  local ctl = state.ctl
  local meters = state.meters
  local scope = state.scope
  local ES = events.ES
  local RING = events.RING
  local MAXB = engine.MAXB

  local strips = {} // in the order they render
  local by_slot = {} // slot -> strip
  local instances = {} // unit id -> {inst, unit}
  local owners = {} // cell -> {inst, index}: whose set() hears of it
  local lfos = {}
  local targets = {} // the cells LFOs move
  local routed = {} // cell -> true
  local pending = {} // instructions not yet due, by time
  local played = 0
  local master = null
  local seed = 987654321
  // a MIDI controller that plays a track: read every block, in whatever
  // isolate the engine runs
  local midi_in = null
  local midi_asked = false
  local midi_target = -1

  local func random(){
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 1073741824.0 - 1.0
  }

  // ---------------------------------------------------------- the layout

  // a strip's left and right gain: its fader, pan and mute
  local func gains(strip){
    local b = strip.base
    local g = eff[b]
    if(eff[b + 2] >= 0.5){
      g = 0.0
    }
    local pan = eff[b + 1]
    local gl = g
    local gr = g
    if(pan > 0.0){
      gl = g * (1.0 - math.min(pan, 1.0))
    } else if(pan < 0.0){
      gr = g * (1.0 + math.max(pan, -1.0))
    }
    return {gl, gr}
  }

  local func make_unit(u, slot){
    local had = instances[u.id]
    if(had != null and had.name == u.unit){
      return had
    }
    local def = units.find(u.unit)
    local inst = def.new({
      sample_rate: state.sample_rate,
      params: eff,
      base: u.base,
      options: u.options or {},
      block: MAXB,
      meters: meters,
      meter: slot * events.METER,
    })
    return {inst: inst, def: def, name: u.unit, id: u.id, base: u.base}
  }

  local func own(entry){
    if(entry.inst.set != null){
      for(local i = 0; i < entry.def.params.count; i = i + 1){
        owners[entry.base + i] = {inst: entry.inst, index: i}
      }
    }
  }

  local func configure(layout){
    local kept = {}
    local list = {}
    by_slot = {}
    owners = {}
    master = null
    for(local i = 0; i < len(layout.strips); i = i + 1){
      local s = layout.strips[i]
      local old = null
      for(local k = 0; k < len(strips); k = k + 1){
        if(strips[k].id == s.id){
          old = strips[k]
        }
      }
      local strip = {
        id: s.id,
        slot: s.slot,
        kind: s.kind,
        base: s.base,
        to: s.to,
        sends: s.sends or {},
        l: null,
        r: null,
        gl: 0.0,
        gr: 0.0,
        send_g: {},
        instrument: null,
        inserts: {},
        mark: 0,
      }
      if(old != null){
        strip.l = old.l
        strip.r = old.r
        strip.gl = old.gl
        strip.gr = old.gr
      } else {
        strip.l = kernel.float:array(MAXB)
        strip.r = kernel.float:array(MAXB)
      }
      if(s.instrument != null){
        strip.instrument = make_unit(s.instrument, s.slot)
        kept[s.instrument.id] = strip.instrument
        own(strip.instrument)
      }
      for(local k = 0; k < len(s.inserts or {}); k = k + 1){
        local u = s.inserts[k]
        local entry = make_unit(u, s.slot)
        kept[u.id] = entry
        own(entry)
        append(strip.inserts, {
          entry: entry, inst: entry.inst, sidechain: u.sidechain
        })
      }
      // a new strip (or send) starts at its level: nothing fades in. One
      // that was there keeps where its ramp is.
      if(old == null){
        local g = gains(strip)
        strip.gl = g[0]
        strip.gr = g[1]
      }
      for(local k = 0; k < len(strip.sends); k = k + 1){
        local cell = strip.sends[k].cell
        strip.send_g[k] = eff[cell]
        if(old != null){
          for(local j = 0; j < len(old.sends); j = j + 1){
            if(old.sends[j].cell == cell){
              strip.send_g[k] = old.send_g[j]
            }
          }
        }
      }
      by_slot[s.slot] = strip
      if(s.kind == "master"){
        master = strip
      }
      append(list, strip)
    }
    // units that are gone
    for(let local e in entries(instances)){
      if(kept[e[0]] == null and e[1].inst.close != null){
        e[1].inst.close()
      }
    }
    instances = kept
    // the controller: opened when a layout first asks for one (or given,
    // by a program that renders here)
    midi_target = -1
    if(layout.midi != null){
      midi_target = layout.midi.target
      if(type(layout.midi.input) == "table"){
        midi_in = layout.midi.input
      } else if(not midi_asked){
        midi_asked = true
        midi_in = try { require("midi").open(layout.midi.input) } catch { null }
      }
    }
    // the order: tracks (one whose insert listens to another track after
    // it), then buses, then the master
    local order = {}
    local func visit(strip){
      if(strip.mark != 0){
        return null
      }
      strip.mark = 1
      for(local k = 0; k < len(strip.inserts); k = k + 1){
        local sc = strip.inserts[k].sidechain
        if(sc != null and sc >= 0 and by_slot[sc] != null and
          by_slot[sc].kind == strip.kind){
          visit(by_slot[sc])
        }
      }
      append(order, strip)
    }
    for(let local kind in values({"track", "bus", "master"})){
      for(local i = 0; i < len(list); i = i + 1){
        if(list[i].kind == kind){
          visit(list[i])
        }
      }
    }
    strips = order
    // the LFOs keep their phases
    local old_lfos = lfos
    lfos = {}
    for(local i = 0; i < len(layout.lfos or {}); i = i + 1){
      local d = layout.lfos[i]
      local o = {
        id: d.id, base: d.base, phase: 0.0, from: 0.0, to: random(), value: 0.0
      }
      for(local k = 0; k < len(old_lfos); k = k + 1){
        if(old_lfos[k].id == d.id){
          o.phase = old_lfos[k].phase
          o.from = old_lfos[k].from
          o.to = old_lfos[k].to
        }
      }
      append(lfos, o)
    }
    // a cell no LFO moves any more is as it was set
    for(local i = 0; i < len(targets); i = i + 1){
      local c = targets[i].cell
      eff[c] = vals[c]
      local o = owners[c]
      if(o != null){
        o.inst.set(o.index, vals[c])
      }
    }
    targets = {}
    routed = {}
    for(local i = 0; i < len(layout.routes or {}); i = i + 1){
      local d = layout.routes[i]
      local lfo = null
      for(local k = 0; k < len(lfos); k = k + 1){
        if(lfos[k].id == d.lfo){
          lfo = lfos[k]
        }
      }
      if(lfo == null){
        continue
      }
      local target = null
      for(local k = 0; k < len(targets); k = k + 1){
        if(targets[k].cell == d.cell){
          target = targets[k]
        }
      }
      if(target == null){
        target = {
          cell: d.cell,
          p: {min: d.min, max: d.max, curve: d.curve},
          routes: {},
          last: null,
        }
        append(targets, target)
        routed[d.cell] = true
      }
      append(target.routes, {lfo: lfo, depth: d.depth})
    }
  }

  local func message(id, m){
    local entry = instances[id]
    if(entry != null and entry.inst.message != null){
      entry.inst.message(m)
    }
  }

  // ---------------------------------------------------------- modulation

  local func modulate(n){
    local dt = n / sr
    for(local i = 0; i < len(lfos); i = i + 1){
      local o = lfos[i]
      local ph = o.phase + eff[o.base] * dt
      if(ph >= 1.0){
        ph = ph - math.floor(ph)
        o.from = o.to
        o.to = random()
      }
      o.phase = ph
      local shape = to_int(eff[o.base + 1])
      local v = 0.0
      if(shape == 0){
        v = math.sin(2 * math.pi * ph)
      } else if(shape == 1){
        v = 1.0 - 4.0 * math.abs(ph - 0.5)
      } else if(shape == 2){
        v = 2.0 * ph - 1.0
      } else if(shape == 3){
        v = if(ph < 0.5){ 1.0 } else { -1.0 }
      } else if(shape == 4){
        v = o.to
      } else {
        local e = 0.5 - 0.5 * math.cos(math.pi * ph)
        v = o.from + (o.to - o.from) * e
      }
      o.value = v
      eff[o.base + 2] = v
    }
    for(local i = 0; i < len(targets); i = i + 1){
      local t = targets[i]
      local sum = 0.0
      for(local k = 0; k < len(t.routes); k = k + 1){
        local r = t.routes[k]
        sum = sum + r.lfo.value * eff[r.depth]
      }
      local v = vals[t.cell]
      if(sum != 0.0){
        v = param.from_t(t.p, param.t_of(t.p, v) + sum)
      }
      if(v != t.last){
        t.last = v
        eff[t.cell] = v
        local o = owners[t.cell]
        if(o != null){
          o.inst.set(o.index, v)
        }
      }
    }
  }

  // ---------------------------------------------------------- instructions

  local func apply(e){
    local kind = e.kind
    if(kind == K.PARAM){
      local cell = e.target
      vals[cell] = e.a
      if(routed[cell] == null){
        eff[cell] = e.a
        local o = owners[cell]
        if(o != null){
          o.inst.set(o.index, e.a)
        }
      }
      return null
    }
    if(e.target < 0){
      // every track
      for(local i = 0; i < len(strips); i = i + 1){
        local inst = strips[i].instrument
        if(inst != null){
          if(kind == K.HUSH and inst.inst.hush != null){
            inst.inst.hush()
          } else if(kind == K.PANIC and inst.inst.panic != null){
            inst.inst.panic()
          }
        }
      }
      return null
    }
    local strip = by_slot[e.target]
    if(strip == null or strip.instrument == null){
      return null
    }
    local inst = strip.instrument.inst
    if(kind == K.NOTE_ON){
      inst.note_on(e.a, e.b)
    } else if(kind == K.NOTE_OFF){
      inst.note_off(e.a)
    } else if(kind == K.NEXT){
      if(inst.next != null){
        inst.next(to_int(e.a), e.b)
      }
    } else if(kind == K.CONTROL){
      if(inst.control != null){
        inst.control(to_int(e.a), e.b)
      }
    } else if(kind == K.HUSH){
      if(inst.hush != null){
        inst.hush()
      }
    } else if(kind == K.PANIC){
      if(inst.panic != null){
        inst.panic()
      }
    }
  }

  // the controller's notes, wheels and pedal to its track, now: they
  // sound within a block of being played
  local func take_midi(){
    if(midi_in == null or midi_target < 0){
      return null
    }
    local C = events.controls
    for(let local m in values(midi_in:read())){
      if(m.kind == "note_on"){
        apply({
          kind: K.NOTE_ON, target: midi_target, a: m.note * 1.0,
          b: m.velocity / 127
        })
      } else if(m.kind == "note_off"){
        apply({kind: K.NOTE_OFF, target: midi_target, a: m.note * 1.0, b: 0.0})
      } else if(m.kind == "bend"){
        apply({kind: K.CONTROL, target: midi_target, a: C.BEND, b: m.value})
      } else if(m.kind == "cc" and m.controller == 1){
        apply({
          kind: K.CONTROL, target: midi_target, a: C.MOD, b: m.value / 127
        })
      } else if(m.kind == "cc" and m.controller == 64){
        apply({
          kind: K.CONTROL, target: midi_target, a: C.SUSTAIN,
          b: if(m.value >= 64){ 1.0 } else { 0.0 }
        })
      }
    }
  }

  // the ring's new instructions into pending, which stays sorted by time
  // (those of one time in the order they were sent)
  local func take(){
    local w = to_int(ctl[0])
    local r = to_int(ctl[1])
    for(r < w){
      local base = (r % RING) * ES
      local e = {
        time: ring[base],
        kind: to_int(ring[base + 1]),
        target: to_int(ring[base + 2]),
        a: ring[base + 3],
        b: ring[base + 4],
        c: ring[base + 5],
      }
      local at = len(pending)
      for(at > 0 and pending[at - 1].time > e.time){
        at = at - 1
      }
      if(at == len(pending)){
        append(pending, e)
      } else {
        local k = len(pending)
        for(k > at){
          pending[k] = pending[k - 1]
          k = k - 1
        }
        pending[at] = e
      }
      r = r + 1
    }
    ctl[1] = r
  }

  // ---------------------------------------------------------- the sound

  local func segment(out, base, start, n){
    modulate(n)
    local decay = math.exp(-n / (sr * 0.3))
    // buses and the master gather what is mixed into them
    for(local i = 0; i < len(strips); i = i + 1){
      local s = strips[i]
      if(s.instrument == null){
        clear(s.l, s.r, start, n)
      }
    }
    for(local i = 0; i < len(strips); i = i + 1){
      local s = strips[i]
      local l = s.l
      local r = s.r
      if(s.instrument != null){
        local inst = s.instrument.inst
        inst.render(l, r, start, n)
        if(inst.voices != null){
          meters[s.slot * events.METER + 2] = inst.voices()
        }
      }
      for(local k = 0; k < len(s.inserts); k = k + 1){
        local fx = s.inserts[k]
        local sc = null
        if(fx.sidechain != null and fx.sidechain >= 0){
          sc = by_slot[fx.sidechain]
        }
        if(sc != null){
          fx.inst.render(l, r, start, n, sc.l, sc.r)
        } else {
          fx.inst.render(l, r, start, n, l, r)
        }
      }
      local g = gains(s)
      local gl = g[0]
      local gr = g[1]
      if(s.kind == "master"){
        local at = deliver(
          out, base, l, r, start, n, s.gl, gl, scope, to_int(ctl[3])
        )
        ctl[3] = at
        meter(l, r, start, n, 1.0, 1.0, meters, s.slot * events.METER, decay)
        s.gl = gl
        s.gr = gl
        continue
      }
      meter(l, r, start, n, gl, gr, meters, s.slot * events.METER, decay)
      local dst = by_slot[s.to] or master
      if(dst != null){
        mix(dst.l, dst.r, l, r, start, n, s.gl, gl, s.gr, gr)
      }
      for(local k = 0; k < len(s.sends); k = k + 1){
        local send = s.sends[k]
        local bus = by_slot[send.to]
        local a = eff[send.cell]
        local before = s.send_g[k]
        if(bus != null and (a != 0.0 or before != 0.0)){
          mix(
            bus.l, bus.r, l, r, start, n, s.gl * before, gl * a, s.gr * before,
            gr * a
          )
        }
        s.send_g[k] = a
      }
      s.gl = gl
      s.gr = gr
    }
  }

  // frames of sound from frame `base` of out on (MAXB at most), split at
  // the instructions due
  local func chunk(out, base, frames){
    local pos = 0
    local stop = played + frames
    local i = 0
    for(i < len(pending)){
      local e = pending[i]
      if(e.time >= stop){
        break
      }
      local at = to_int(e.time) - played
      if(at > pos){
        segment(out, base, pos, at - pos)
        pos = at
      }
      apply(e)
      i = i + 1
    }
    if(i > 0){
      local rest = {}
      for(local k = i; k < len(pending); k = k + 1){
        append(rest, pending[k])
      }
      pending = rest
    }
    if(frames > pos){
      segment(out, base, pos, frames - pos)
    }
    played = stop
    ctl[2] = played
  }

  local func block(out, frames){
    take_midi()
    take()
    local base = 0
    for(base < frames){
      local n = math.min(frames - base, MAXB)
      chunk(out, base, n)
      base = base + n
    }
  }

  // the instructions that are due now, without rendering: offline, a
  // parameter set from the program's side holds at once
  local func flush(){
    take()
    local i = 0
    for(i < len(pending) and pending[i].time <= played){
      apply(pending[i])
      i = i + 1
    }
    if(i > 0){
      local rest = {}
      for(local k = i; k < len(pending); k = k + 1){
        append(rest, pending[k])
      }
      pending = rest
    }
  }

  local func poll(commands){
    for(true){
      local m = commands:try_receive()
      if(m == null){
        return null
      }
      if(m.layout != null){
        configure(m.layout)
      } else if(m.unit != null){
        message(m.unit, m.message)
      }
    }
  }

  return {
    block: block,
    configure: configure,
    message: message,
    take: take,
    flush: flush,
    poll: poll,
  }
}

// stream(state: State, layout: table, commands: Channel) -> block function
// What an audio stream's setup function returns: an engine with the
// layout, hearing of changes on commands.
func engine.stream(state, layout, commands){
  local e = engine.new(state)
  e.configure(layout)
  return func(out, frames){
    e.poll(commands)
    e.block(out, frames)
  }
}

return engine
