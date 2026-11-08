local t = require("slang/test")
local os = require("slang/os")
local path = require("slang/path")
local math = require("slang/math")
local pattern = require("pattern")
local offline = require("offline")

// The live environment without a window or an audio device: the
// notation, the patterns, the scheduler and the engine, and every piece.

local here = __PACKAGES.search_paths[0]

// equal, lists element by element
local func eq(a, b, message){
  local same = true
  if(type(a) == "table" and type(b) == "table"){
    same = len(a) == len(b)
    for(local i = 0; same and i < len(a); i = i + 1){
      same = a[i] == b[i]
    }
  } else {
    same = a == b
  }
  assert(same, concat(
    message or "", " expected ", string(b), ", got ", string(a)
  ))
}

local func values_of(events){
  local out = {}
  for(let local e in values(events)){
    append(out, e.value)
  }
  return out
}

local func peak_of(buf, from, to){
  local peak = 0.0
  for(local i = from; i < to; i = i + 1){
    local v = buf[i]
    if(v < 0){
      v = -v
    }
    if(v > peak){
      peak = v
    }
  }
  return peak
}

local func finite(buf){
  for(local i = 0; i < len(buf); i = i + 1){
    local v = buf[i]
    if(v - v != 0){
      return false
    }
  }
  return true
}

t.group("notation", func(){
  t.test("steps, rests, holds and modifiers", func(){
    local e = `0.2_ -1 3# 4b 0= 0! 0^ 0v 5g`:events(0)
    eq(values_of(e), {0, 2, -1, 3, 4, 0, 0, 0, 0, 5})
    eq(e[1].len, 2.0)
    eq(e[3].acc, 1)
    eq(e[4].acc, -1)
    eq(e[5].len, 1.5)
    assert(math.abs(e[6].len - 2.0 / 3.0) < 0.0001)
    eq(e[7].vel, 1.5)
    assert(math.abs(e[8].vel - 2.0 / 3.0) < 0.0001)
    eq(e[9].flags, "g")
  })
  t.test("subsequence, chord and supersequence", func(){
    local p = `0[12](35)<67>`
    eq(p:steps(), 4)
    local e = p:events(0)
    eq(values_of(e), {0, 1, 2, 3, 5, 6})
    eq(e[1].at, 1.0)
    eq(e[1].len, 0.5)
    eq(e[2].at, 1.5)
    eq(e[3].at, e[4].at)
    eq(values_of(p:events(1)), {0, 1, 2, 3, 5, 7})
    // nested supersequences count their own turns
    eq(values_of(`<1<23>>`:events(3)), {3})
  })
  t.test("drum letters and splices", func(){
    eq(values_of(`x-o-`:events(0)), {"x", "-", "o", "-"})
    local fill = `[xx]o`
    local e = `x${fill}${3}${"-+"}`:events(0)
    eq(values_of(e), {"x", "x", "x", "o", 3, "-", "+"})
    eq(e[1].len, 0.25)
    eq(e[5].len, 0.5)
  })
  t.test("whitespace and quotes mean nothing; errors say where", func(){
    eq(values_of(`"01 23"`:events(0)), {0, 1, 2, 3})
    eq(pattern.parse(" 0 1 "):steps(), 2)
    local err = try { pattern.parse("0[1") } catch(local e) { e.message }
    assert(type(err) == "string" and require("slang/string").contains(
        err, "expected"
      ))
  })
})

t.group("patterns", func(){
  t.test("then, times, crop, rev, map", func(){
    eq(values_of(`12`:then(`34`):events(0)), {1, 2, 3, 4})
    eq(values_of(`12`:times(2):events(0)), {1, 2, 1, 2})
    eq(values_of(`01`:crop(5):events(0)), {0, 1, 0, 1, 0})
    eq(values_of(`0123`:crop(2):events(0)), {0, 1})
    eq(values_of(`012`:rev():events(0)), {2, 1, 0})
    eq(`0369`:map(func(v){ return v / 10 }):at(2.5, 1), 0.6)
    eq(`012`:add(10):at(1.0), 11)
  })
  t.test("events between beats, loops and anchors", func(){
    local e = pattern.events_between(`0123`, 0.5, 1.0, 3.0)
    eq(len(e), 4)
    eq(e[0].start, 1.0)
    eq(e[0].value, 2)
    eq(e[2].rep, 1)
    local looped = pattern.events_between(`01`:loop(2), 1.0, 0.0, 10.0)
    eq(len(looped), 4)
    local anchored = pattern.events_between(`01`, 1.0, 10.0, 12.0, 10.0)
    eq(anchored[0].value, 0)
    eq(anchored[0].start, 10.0)
    eq(len(pattern.events_between(`0`, 1.0, -3.0, 0.0)), 0)
  })
  t.test("scales and note names", func(){
    eq(pattern.note_name("c4"), 60)
    eq(pattern.note_name("eb3"), 51)
    eq(pattern.note_name("f#"), 66)
    eq(pattern.note_name(61), 61)
    eq(pattern.note_of(0, 0, pattern.scales.minor, 57), 57)
    eq(pattern.note_of(7, 0, pattern.scales.minor, 57), 69)
    eq(pattern.note_of(-1, 0, pattern.scales.minor, 57), 55)
    eq(pattern.note_of(2, 1, pattern.scales.major, 60), 65)
    eq(pattern.note_of(5, 0, pattern.scales.pentatonic, 60), 72)
  })
  t.test("signals", func(){
    assert(math.abs(pattern.sine(4, 0.2, 0.8):at(1.0) - 0.8) < 0.0001)
    assert(math.abs(pattern.sine(4):at(0.0) - 0.5) < 0.0001)
    eq(pattern.saw(2):at(1.0), 0.5)
    eq(pattern.square(2):at(1.5), 0.0)
    eq(pattern.steps({1, 2, 3}, 1):at(4.5), 2)
    eq(pattern.steps({0, 10}, 1, true):at(0.5), 5.0)
    local r = pattern.rand(1)
    eq(r:at(2.2), r:at(2.9))
    assert(r:at(2.2) != r:at(3.2))
    eq(pattern.sine(4):range(10, 20):at(1.0), 20.0)
    // arithmetic: signals and numbers add up to a signal
    local s = pattern.sine(4, 0, 1)
    assert(math.abs((s + 1):at(1.0) - 2.0) < 0.0001)
    assert(math.abs((2 * s):at(1.0) - 2.0) < 0.0001)
    assert(math.abs((s - s):at(0.3)) < 0.0001)
    assert(math.abs((-s):at(1.0) + 1.0) < 0.0001)
    assert(math.abs((s / 4):at(1.0) - 0.25) < 0.0001)
    assert(math.abs((1 - s):at(3.0) - 1.0) < 0.0001)
    assert(pattern.is_signal(s + pattern.saw(8)))
    eq(pattern.value_at(3, 1.0), 3)
    eq(pattern.value_at(`05`, 1.0, 1.0), 5)
  })
})

t.group("engine and session", func(){
  t.test("a note sounds on the beat and stops", func(){
    local r = offline.run("""
      bpm(120)
      play("a", "sine", `0...`, {dur: 1, decay: 0.05, sustain: 1.0, release: 0.02, legato: 0.5})
    """, 2.0)
    assert(finite(r.left))
    // the note takes beat 0 to 0.5 (legato 0.5 of a 1-beat step), 0.25 s,
    // and nothing else sounds in the two seconds
    assert(peak_of(r.left, 0, 12000) > 0.1)
    assert(peak_of(r.left, 18000, 48000) < 0.01)
    assert(peak_of(r.left, 72000, 96000) < 0.01)
  })
  t.test("pitch follows the scale and the root", func(){
    // degree 7 of a minor over a2 (45) is a3: 220 Hz, 440 crossings a second
    local r = offline.run("""
      bpm(60)
      scale("minor", "a2")
      play("a", "sine", `7`, {dur: 4, attack: 0.001, decay: 0.01, sustain: 1.0, cutoff: 1.0})
    """, 2.0)
    local crossings = 0
    for(local i = 48001; i < 96000; i = i + 1){
      if((r.left[i - 1] < 0) != (r.left[i] < 0)){
        crossings = crossings + 1
      }
    }
    assert(crossings > 430 and crossings < 450, concat("crossings ", crossings))
  })
  t.test("drums, every wave and the effects render finite sound", func(){
    local r = offline.run("""
      bpm(120)
      play("d", "drum", `xXoO-+ctTrb`, {dur: 1/4, delay: 0.3, room: 0.5})
      play("e", "808", `xXoO-+ctTrb`, {dur: 1/4, pan: 0.5})
      play("w1", "saw", `0`, {dur: 1/2, detune: 7, drive: 0.5})
      play("w2", "square", `0`, {dur: 1/2, detune: 7, pw: 0.2})
      play("w3", "tri", `0`, {dur: 1/2})
      play("w4", "noise", `0`, {dur: 1/2, cutoff: 0.5, res: 0.9})
      play("w5", "fm", `0`, {dur: 1/2, fm: 5, ratio: 3.01})
      play("g", "supersaw", `(047) 7`, {dur: 1/2, glide: 0.1, detune: 25, pw: 0.7, cutoff: 0.7})
      delay(0.5, 0.6, 0.8)
      reverb(0.9, 0.2)
      master(0.9)
    """, 2.0)
    assert(finite(r.left) and finite(r.right))
    assert(peak_of(r.left, 0, len(r.left)) > 0.1)
    assert(peak_of(r.left, 0, len(r.left)) <= 1.0)
    eq(count(r.S.players), 8)
  })
  t.test("the supersaw is seven saws: wider than one, beating slowly", func(){
    local one = offline.run("play(\"a\", \"saw\", `0`, {dur: 8, sustain: 1.0, cutoff: 1.0, gain: 0.3})", 1.0)
    local seven = offline.run("play(\"a\", \"supersaw\", `0`, {dur: 8, sustain: 1.0, cutoff: 1.0, gain: 0.3, detune: 30})", 1.0)
    assert(finite(seven.left) and peak_of(seven.left, 0, len(seven.left)) <= 1.0)
    // the sum of detuned saws drifts in level between windows, one saw
    // does not
    local func rms(left, from, to){
      local e = 0.0
      for(local i = from; i < to; i = i + 1){
        e = e + left[i] * left[i]
      }
      return (e / (to - from)) ^ 0.5
    }
    local spread_one = 0.0
    local spread_seven = 0.0
    local w = 2400
    for(local k = 2; k < 18; k = k + 1){
      local a = rms(one.left, k * w, (k + 1) * w)
      local b = rms(one.left, (k + 1) * w, (k + 2) * w)
      spread_one = math.max(spread_one, math.abs(a - b))
      a = rms(seven.left, k * w, (k + 1) * w)
      b = rms(seven.left, (k + 1) * w, (k + 2) * w)
      spread_seven = math.max(spread_seven, math.abs(a - b))
    }
    assert(spread_seven > spread_one * 3, concat("one ", spread_one, " seven ", spread_seven))
  })
  t.test("the 808: a closed hat chokes an open one, the kick is low", func(){
    local func energy(left, from, to){
      local e = 0.0
      for(local i = to_int(from * 48000); i < to_int(to * 48000); i = i + 1){
        e = e + left[i] * left[i]
      }
      return e
    }
    // at 120 BPM a quarter step is 125 ms: the open hat on its own rings
    // past 0.3 s; with a closed hat 125 ms after it, it is cut
    local open = offline.run("bpm(120)\nplay(\"h\", \"808\", `+...`, {dur: 1/4})", 0.5)
    local choked = offline.run("bpm(120)\nplay(\"h\", \"808\", `+-..`, {dur: 1/4})", 0.5)
    assert(energy(open.left, 0.3, 0.5) > 0.01, "the open hat rings")
    assert(energy(choked.left, 0.3, 0.5) < energy(open.left, 0.3, 0.5) * 0.2, "not choked")
    local kick = offline.run("bpm(120)\nplay(\"k\", \"808\", `x...`, {dur: 1/4, gain: 0.7})", 0.4)
    local crossings = 0
    for(local i = to_int(0.1 * 48000) + 1; i < to_int(0.3 * 48000); i = i + 1){
      if(kick.left[i - 1] < 0 and kick.left[i] >= 0){
        crossings = crossings + 1
      }
    }
    assert(crossings > 7 and crossings < 16, concat("kick crossings in 0.2 s: ", crossings))
    assert(peak_of(kick.left, 0, len(kick.left)) > 0.3)
  })
  t.test("set changes a sounding voice, hush silences, players go away", func(){
    local o = offline.new()
    local r = o.S:eval("""
      bpm(120)
      play("a", "saw", `0`, {dur: 8, sustain: 1.0, gain: 0.5, cutoff: 1.0})
      play("b", "saw", `0`, {dur: 8, sustain: 1.0, gain: 0.5, cutoff: 1.0})
    """, "t")
    assert(r.ok, r.message)
    local s = offline.render(o, 0.5)
    local loud = peak_of(s.left, 12000, 24000)
    r = o.S:eval("""
      bpm(120)
      play("a", "saw", `0`, {dur: 8, sustain: 1.0, gain: 0.5, cutoff: 1.0})
      set("a", {gain: 0.05})
    """, "t")
    assert(r.ok, r.message)
    eq(count(o.S.players), 1)
    s = offline.render(o, 0.5)
    local quiet = peak_of(s.left, 12000, 24000)
    assert(quiet < loud * 0.5, concat("loud ", loud, " quiet ", quiet))
    o.S:hush()
    s = offline.render(o, 2.0)
    assert(peak_of(s.left, 72000, 96000) < 0.001)
  })
  t.test("a control is a parameter and keeps its value", func(){
    local o = offline.new()
    local src = """
      local g = slider("gain", 0.4, 0, 1)
      play("a", "saw", `0`, {dur: 1, gain: g})
    """
    assert(o.S:eval(src, "t").ok)
    eq(o.S.controls.gain.value, 0.4)
    o.S:set_control("gain", 0.9)
    assert(o.S:eval(src, "t").ok)
    eq(o.S.controls.gain.value, 0.9)
    eq(len(o.S.control_list), 1)
    assert(o.S:eval("play(\"a\", \"saw\", `0`)", "t").ok)
    eq(len(o.S.control_list), 0)
  })
  t.test("a slider's value reaches the sound, and adds up with a signal", func(){
    local quiet = offline.run("""
      local g = slider("gain", 0.1, 0, 1)
      play("a", "saw", `0`, {dur: 1, gain: g, cutoff: 1.0})
    """, 0.5)
    local o = offline.new()
    local src = """
      local g = slider("gain", 0.1, 0, 1)
      play("a", "saw", `0`, {dur: 1, gain: g, cutoff: 1.0})
    """
    assert(o.S:eval(src, "t").ok)
    o.S:set_control("gain", 0.8)
    local loud = offline.render(o, 0.5)
    local lo = peak_of(quiet.left, 6000, 24000)
    local hi = peak_of(loud.left, 6000, 24000)
    assert(hi > lo * 4, concat("slider 0.1: ", lo, "  0.8: ", hi))
    // the sum of a slider and a signal, set live and at the note
    local r = offline.run("""
      local cut = slider("cutoff", 0.4, 0.1, 0.9)
      play("a", "saw", `0`, {dur: 1, cutoff: cut + sine(4, -0.2, 0.2)})
      set("a", {pan: cut * 2 - 1})
    """, 0.5)
    assert(finite(r.left) and peak_of(r.left, 0, len(r.left)) > 0.05)
    local p = r.S.players.a
    assert(pattern.is_signal(p.params.cutoff), "the sum is a signal")
    assert(math.abs(p.params.cutoff:at(1.0) - 0.6) < 0.0001)
  })
  t.test("the notation declares every function of the api", func(){
    local declared = {}
    for(let local n in values(require("notation").api_names)){
      declared[n] = true
    }
    for(let local n in values(require("api").names())){
      assert(declared[n], concat(n, " is not declared in notation.slang"))
    }
  })
  t.test("errors are reported with their line", func(){
    local o = offline.new()
    local r = o.S:eval("bpm(120)\nplay(\"a\", \"saw\", `0[1`)\n", "t")
    assert(not r.ok)
    eq(r.line, 2)
    r = o.S:eval("bpm(120)\nplay(\"a\", \"nope\", `0`)\n", "t")
    assert(not r.ok)
    assert(require("slang/string").contains(r.message, "no wave"))
  })
  t.test("the keyboard and midi play the players of their source", func(){
    local o = offline.new()
    assert(o.S:eval("""
      bpm(120)
      play("k", "sine", keyboard(), {sustain: 1.0, release: 0.01})
      play("m", "sine", midi(), {sustain: 1.0, release: 0.01})
    """, "t").ok)
    o.S:key_note(0, 0, 0.8, true, 65)
    o.S:midi_message({kind: "note_on", note: 64, velocity: 100, channel: 1})
    o.S:midi_message({kind: "cc", controller: 74, value: 64, channel: 1})
    assert(math.abs(o.S:cc_value(74) - 64 / 127) < 0.001)
    local s = offline.render(o, 0.3)
    assert(peak_of(s.left, 4800, 14400) > 0.1)
    o.S:key_note(0, 0, 0, false, 65)
    o.S:midi_message({kind: "note_off", note: 64, velocity: 0, channel: 1})
    s = offline.render(o, 0.5)
    assert(peak_of(s.left, 12000, 24000) < 0.001)
  })
})

t.group("glsl", func(){
  local glsl = require("glsl")
  t.test("a body, a main and a Shadertoy mainImage each become a program", func(){
    local s = require("slang/string")
    local body = glsl.program("color = vec3(uv, 0.0);", {"k"})
    assert(s.contains(body, "uniform float k;") and s.contains(body, "vec2 uv = gl_FragCoord.xy / resolution;"))
    assert(s.contains(body, "mat2 rot(") and s.contains(body, "finalColor = vec4(color, 1.0);"))
    local main = glsl.program("mat2 rot(float a){ return mat2(1.0); }\nvoid main(){ finalColor = vec4(1.0); }", {})
    eq(glsl.kind(main), "main")
    assert(s.index_of(main, "mat2 rot(") == s.last_index_of(main, "mat2 rot("), "the prelude's rot is left out")
    assert(not s.contains(main, "vec2 uv = gl_FragCoord"))
    local image = glsl.program("void mainImage(out vec4 c, in vec2 f){ c = vec4(f / iResolution.xy, iTime, 1.0); }", {})
    assert(s.contains(image, "#define iResolution vec3(resolution, 1.0)"))
    assert(s.contains(image, "void main(){ mainImage(finalColor, gl_FragCoord.xy); }"))
    assert(s.contains(image, "uniform vec4 imouse;"))
  })
})

t.group("editor", func(){
  local editor = require("editor")
  t.test("typing, lines, selection, undo", func(){
    local E = editor.new("ab\ncd\n")
    eq(len(E.lines), 3)
    E:click(0, 1)
    E:insert("X")
    eq(E.lines[0], "aXb")
    E:newline()
    eq(E:text(), "aX\nb\ncd\n")
    eq(E.cy, 1)
    E:backspace()
    eq(E.lines[0], "aXb")
    E:insert("{")
    E:newline()
    eq(E.lines[1], "  b")
    E.sel = {x: 0, y: 0}
    E:click(1, 2, true)
    eq(E:selection_text(), "aX{\n  ")
    E:snapshot()
    E:delete_selection()
    eq(E:text(), "b\ncd\n")
    E:restore()
    eq(E:text(), "aX{\n  b\ncd\n")
    E:select_all()
    E:insert("z")
    eq(E:text(), "z")
    assert(E.dirty)
  })

  t.test("copy and cut take the line without a selection, paste puts it above", func(){
    local E = editor.new("one\ntwo\nthree\n")
    E:click(1, 2)
    eq(E:copy_text(), "two\n")
    E:click(0, 1)
    E:paste("two\n")
    eq(E:text(), "two\none\ntwo\nthree\n")
    eq(E.cy, 1)
    eq(E.cx, 0)
    // a selection copies and pastes as text, wherever the cursor is
    E:click(0, 0)
    E:click(0, 2, true)
    eq(E:copy_text(), "tw")
    E:click(1, 3)
    E:paste("tw")
    eq(E.lines[1], "onetw")
    E:click(2, 1)
    eq(E:cut_text(), "two\n")
    eq(E:text(), "two\nonetw\nthree\n")
    E:restore()
    eq(E:text(), "two\nonetw\ntwo\nthree\n")
  })

  t.test("command+K comments the selected lines and uncomments them again", func(){
    local E = editor.new("play(\"a\")\n  set(1)\n\n  hush()\nbpm(120)\n")
    E:click(0, 0)
    E:click(3, 2, true)
    E:toggle_comment()
    eq(E:text(), "// play(\"a\")\n//   set(1)\n\n//   hush()\nbpm(120)\n")
    eq(E.cx, 5)
    E:toggle_comment()
    eq(E:text(), "play(\"a\")\n  set(1)\n\n  hush()\nbpm(120)\n")
    eq(E.cx, 2)
    // a selection ending at a line's start leaves that line out; without
    // a selection the cursor's line is taken
    E:click(0, 0)
    E:click(1, 0, true)
    E:toggle_comment()
    eq(E.lines[0], "// play(\"a\")")
    eq(E.lines[1], "  set(1)")
    E:click(4, 3)
    E:toggle_comment()
    eq(E.lines[4], "// bpm(120)")
    eq(E.cx, 6)
    E:restore()
    eq(E.lines[4], "bpm(120)")
    // comments without a space after the slashes come off as well
    local F = editor.new("//x\n")
    F:toggle_comment()
    eq(F.lines[0], "x")
  })
})

t.group("layout", func(){
  t.test("every letter has a key, the keys are letter keys and distinct", func(){
    local layout = require("layout")
    local seen = {}
    for(local c = 97; c <= 122; c = c + 1){
      local letter = require("slang/string").from_bytes({c})
      local k = layout.key(letter)
      // 0: the layout has no key for the letter and its US place is taken
      assert(k == 0 or (k >= 39 and k <= 161), concat(letter, " -> ", k))
      assert(k == 0 or seen[k] == null, concat("two letters on key ", k))
      seen[k] = letter
    }
    // on macOS the layout is read: the map covers the letters, and the
    // key that types a letter types that letter (not another)
    local keys = layout.keys()
    if(keys != null){
      assert(count(keys) >= 24, concat("letters read: ", count(keys)))
    }
  })
})

t.group("pieces", func(){
  for(let local name in values(os.list_dir(path.join(here, "pieces")))){
    if(not require("slang/string").ends_with(name, ".slang")){
      continue
    }
    t.test(name, func(){
      local p = path.join(here, "pieces", name)
      local r = offline.run(os.read_file(p), 4.0, p)
      assert(finite(r.left) and finite(r.right))
      assert(peak_of(r.left, 0, len(r.left)) > 0.05, "silent")
      assert(peak_of(r.left, 0, len(r.left)) <= 1.0)
      assert(r.S.shader_source != null, "no shader")
    })
  }
})
