extension "kernel/syntax"
local t = require("slang/test")
local str = require("slang/string")
local kernel = require("kernel")

// Kernels written in a slang file: kernel { ... } (kernel/syntax).

kernel {
  struct Voice {
    phase: double,
    inc: double = 0.25,
    gain: float = 0.5,
  }

  local blocks = 0
  local HALF = 0.5

  local func wrap(x: float): float {
    return x - floor(x)
  }

  // the voices' saws summed into out; how many blocks so far
  func render(out: float[], voices: Voice[], n: int): int {
    for(local i = 0; i < n; i += 1){
      local s = 0.0
      for(local k = 0; k < len(voices); k += 1){
        local v = voices[k]
        v.phase = wrap(v.phase + v.inc)
        s += (v.phase * 2 - 1) * v.gain
      }
      out[i] = s * HALF
    }
    blocks += 1
    return blocks
  }

  func level(v: Voice): float {
    return v.gain
  }

  func at(out: float[], i: int): float {
    return out[i]
  }
}

kernel {
  use "test/shapes"

  // shapes' Point, SCALE and norm1, as if written here
  func total(ps: Point[]): float {
    local s = 0.0
    for(local i = 0; i < len(ps); i += 1){
      s += norm1(ps[i]) * SCALE
    }
    return s
  }
}

t.group("kernel blocks"){
  t.test("structs and entry points are locals of the slang code"){
    local voices = Voice:array({{inc: 0.5}, {gain: 1}})
    local out = kernel.float:array(4)
    assert(render(out, voices, 4) == 1)
    // phases 0.5, 0, 0.5, 0 and 0.25, 0.5, 0.75, 0
    assert(out[0] == ((0.5 * 2 - 1) * 0.5 + (0.25 * 2 - 1)) * 0.5)
    assert(render(out, voices, 4) == 2)
    assert(level(Voice:new({gain: 2})) == 2.0 and level(voices[0]) == 0.5)
  }
  t.test("helpers, constants and state stay inside"){
    // wrap, HALF and blocks are not slang names here
    local src = """
      extension "kernel/syntax"
      kernel {
        local func hidden(): int { return 1 }
        func shown(): int { return hidden() }
      }
      return {shown: shown(), hidden: hidden}
    """
    local r = require("slang/compiler").compile(src, "inline")()
    assert(r.shown == 1 and r.hidden == null)
  }
  t.test("use: the structs, constants and helpers of another module"){
    local shapes = require("test/shapes")
    // Point is shapes' own value
    assert(Point == shapes.Point)
    local ps = Point:array({{x: -2}, {x: 3, y: 0}})
    assert(total(ps) == 30 + 30)
    assert(shapes.size(ps[0]) == 30.0)
    local msg = t.raises(func(){
      kernel.compile("use \"test/nothing\"\nfunc f(){ }", "u")
    }).message
    assert(str.contains(msg, "use: no kernel module test/nothing"), msg)
  }
  t.test("a run error names the line in this file"){
    local msg = t.raises(func(){ at(kernel.float:array(2), 5) }).message
    assert(str.contains(
      msg,
      "syntax_test.slang:42: kernel at: index 5 out of range",
    ), msg)
  }
}
