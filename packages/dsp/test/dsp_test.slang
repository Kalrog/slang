extension "dsp"
local t = require("slang/test")
local str = require("slang/string")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local kernel = require("kernel")
local grammar = require("dsp/grammar")
local build = require("dsp/build")
local format = require("slang/format")
local compiler = require("slang/compiler")

// The dsp language: what programs compute (against the same thing written
// in slang), what the compiler makes of them, its errors, formatting and
// highlighting.

local here = __PACKAGES.search_paths[0]

// n samples of a program's outputs (a list of arrays), from inputs
local func run(program, n, inputs, setup){
  local v = program:new()
  if(setup != null){
    setup(v)
  }
  local outs = {}
  for(local j = 0; j < program.outputs; j = j + 1){
    append(outs, kernel.float:array(n))
  }
  v:compute(n, inputs or {}, outs)
  return outs
}

local func near(a, b, eps, message){
  assert(math.abs(a - b) <= (eps or 1e-5), concat(
    message or "", " expected ", string(b), ", got ", string(a)
  ))
}

local func ramp(n){
  local a = kernel.float:array(n)
  for(local i = 0; i < n; i = i + 1){
    a[i] = (i % 7) * 0.25 - 0.5
  }
  return a
}

// the loop of a generated kernel: the lines between `for(` and its end
local func loop_of(source){
  local start = str.index_of(source, "  for(local i")
  local stop = str.index_of(source, "\n  }\n")
  return str.substring(source, start, stop)
}

local func count_of(text, part){
  return len(str.split(text, part)) - 1
}

// the error a program's compilation raises
local func error_of(source){
  try {
    build.program(grammar.parse(source, "test.dsp"), "test")
  } catch(local e) {
    return e
  }
  assert(false, "expected a compile error")
}

// ------------------------------------------------------------ programs

dsp wire {
  process = _;
}

dsp twice {
  process = _ <: _, _ :> _;
}

dsp swap {
  process = _, _ <: !, _, _, !;
}

dsp integrate {
  process = + ~ _;
}

dsp late {
  process = _ <: _, _', @(3);
}

dsp ratio {
  process = hslider("x", 1, 0, 10, 0.1) / 4 : *(2);
}

dsp delayed {
  process = @(hslider("d", 2, 0, 9, 1));
}

dsp counted {
  process = par(i, 3, i + 1) :> _, sum(i, 4, i), prod(i, 3, i + 2);
}

dsp lambda {
  twice(f) = f : f;
  process = twice(\(x).(x * 3 + 1));
}

dsp scoped {
  gain(g) = *(k) with {
    k = g * 2;
  };
  process = gain(0.25);
}

dsp smoothed {
  import "std";
  s = hslider("s", 0.5, 0, 1, 0.01) : smoo;
  process = _ * s + s * s;
}

dsp onepole {
  import "std";
  process = smooth(0.9);
}

dsp hisses {
  import "std";
  process = noises(0), noises(1), noises(4);
}

dsp biquad {
  import "std";
  process = lowpass2(1000, 2);
}

dsp constants {
  process = 2 * 3 + 1, sin(0) + 0.5;
}

dsp third {
  import "std";
  process = only(4, 2);
}

dsp calmer {
  import "std";
  process = leveled(0.1, 0.005, 100);
}

t.group("block diagrams"){
  t.test("_ passes its input on"){
    local x = ramp(32)
    local y = run(wire, 32, {x})[0]
    for(local i = 0; i < 32; i = i + 1){
      near(y[i], x[i])
    }
    assert(wire.inputs == 1 and wire.outputs == 1)
  }
  t.test("<: copies outputs round, :> sums them"){
    local x = ramp(16)
    local y = run(twice, 16, {x})[0]
    for(local i = 0; i < 16; i = i + 1){
      near(y[i], x[i] * 2)
    }
  }
  t.test("! cuts a signal"){
    local a = ramp(8)
    local b = kernel.float:array({1, 2, 3, 4, 5, 6, 7, 8})
    local ys = run(swap, 8, {a, b})
    assert(swap.inputs == 2 and swap.outputs == 2)
    for(local i = 0; i < 8; i = i + 1){
      near(ys[0][i], b[i])
      near(ys[1][i], a[i])
    }
  }
  t.test("~ feeds back one sample late: + ~ _ sums its input"){
    local x = ramp(40)
    local y = run(integrate, 40, {x})[0]
    local s = 0.0
    for(local i = 0; i < 40; i = i + 1){
      s = s + x[i]
      near(y[i], s)
    }
  }
  t.test("' and @ delay"){
    local x = ramp(20)
    local ys = run(late, 20, {x})
    for(local i = 0; i < 20; i = i + 1){
      near(ys[0][i], x[i])
      near(ys[1][i], if(i >= 1){ x[i - 1] } else { 0.0 })
      near(ys[2][i], if(i >= 3){ x[i - 3] } else { 0.0 })
    }
  }
  t.test("a delay from a slider is bounded by its range"){
    local x = ramp(30)
    local y = run(delayed, 30, {x}, func(v){ v.d = 5 })[0]
    for(local i = 0; i < 30; i = i + 1){
      near(y[i], if(i >= 5){ x[i - 5] } else { 0.0 })
    }
    assert(delayed.ring == 16, string(delayed.ring))
  }
  t.test("controls are properties of an instance, clamped to their range"){
    local y = run(ratio, 4, {}, func(v){ v.x = 3 })[0]
    near(y[0], 1.5)
    y = run(ratio, 4, {}, func(v){ v.x = 40 })[0]
    near(y[0], 5)
    local v = ratio:new()
    near(v.x, 1)
    v:set("x", 2)
    near(v:get("x"), 2)
    local labels = {}
    for(let local c in values(ratio.controls)){
      append(labels, c.label)
    }
    assert(str.join(labels, ",") == "x")
  }
  t.test("par, seq, sum and prod repeat a diagram"){
    local ys = run(counted, 2)
    near(ys[0][0], 6)
    near(ys[1][0], 6)
    near(ys[2][0], 24)
  }
  t.test("functions take diagrams, lambdas and with"){
    local x = ramp(10)
    local y = run(lambda, 10, {x})[0]
    for(local i = 0; i < 10; i = i + 1){
      near(y[i], (x[i] * 3 + 1) * 3 + 1, 1e-4)
    }
    y = run(scoped, 10, {x})[0]
    for(local i = 0; i < 10; i = i + 1){
      near(y[i], x[i] * 0.5)
    }
  }
  t.test("a one-pole filter as slang computes it"){
    local x = ramp(64)
    local y = run(onepole, 64, {x})[0]
    local s = 0.0
    for(local i = 0; i < 64; i = i + 1){
      s = x[i] * (1 - 0.9) + s * 0.9
      near(y[i], s)
    }
  }
  t.test("a biquad as slang computes it (RBJ lowpass, direct form)"){
    local n = 256
    local x = kernel.float:array(n)
    for(local i = 0; i < n; i = i + 1){
      x[i] = if(i % 40 < 20){ 0.5 } else { -0.5 }
    }
    local y = run(biquad, n, {x})[0]
    local w = 2 * math.pi * 1000 / 48000
    local alpha = math.sin(w) / (2 * 2)
    local a0 = 1 + alpha
    local b0 = (1 - math.cos(w)) / 2 / a0
    local b1 = 2 * b0
    local a1 = -2 * math.cos(w) / a0
    local a2 = (1 - alpha) / a0
    local x1 = 0.0
    local x2 = 0.0
    local y1 = 0.0
    local y2 = 0.0
    for(local i = 0; i < n; i = i + 1){
      local v = b0 * x[i] + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
      x2 = x1
      x1 = x[i]
      y2 = y1
      y1 = v
      near(y[i], v, 1e-4, concat("sample ", string(i)))
    }
  }
  t.test("only passes the one signal, leveled halves the distance to its level"){
    local ins = {ramp(8), ramp(8), kernel.float:array(8), ramp(8)}
    for(local i = 0; i < 8; i = i + 1){
      ins[2][i] = i * 0.5
    }
    local out = run(third, 8, ins)[0]
    for(local i = 0; i < 8; i = i + 1){
      near(out[i], i * 0.5)
    }
    // (and costs nothing: the other three are folded away)
    assert(count_of(loop_of(third.source), "*") == 0, loop_of(third.source))
    // a hundred times louder in, ten times louder out
    local func settled(level){
      local x = kernel.float:array(4000)
      for(local i = 0; i < 4000; i = i + 1){
        x[i] = level
      }
      return run(calmer, 4000, {x})[0][3999]
    }
    near(settled(1.0), math.sqrt(0.1), 0.01)
    near(settled(0.01), 0.01 * math.sqrt(0.1 / 0.01), 0.001)
  }
  t.test("an instance keeps its state between blocks"){
    local x = ramp(64)
    local v = integrate:new()
    local a = kernel.float:array(32)
    local whole = run(integrate, 64, {x})[0]
    local first = x:slice(0, 32)
    local second = x:slice(32, 64)
    v:compute(32, {first}, {a})
    near(a[31], whole[31])
    v:compute(32, {second}, {a})
    near(a[31], whole[63])
    v:reset()
    v:compute(32, {x}, {a})
    near(a[31], whole[31])
  }
}

t.group("the library"){
  t.test("its noises are white, and no two of them alike"){
    local n = 20000
    local outs = run(hisses, n)
    local func alike(a, b){
      local sum = 0.0
      local aa = 0.0
      local bb = 0.0
      for(local i = 0; i < n; i = i + 1){
        sum = sum + a[i] * b[i]
        aa = aa + a[i] * a[i]
        bb = bb + b[i] * b[i]
      }
      return sum / math.sqrt(aa * bb)
    }
    for(local j = 0; j < 3; j = j + 1){
      // (evenly between -1 and 1: its mean square a third)
      near(alike(outs[j], outs[j]), 1)
      local square = 0.0
      for(local i = 0; i < n; i = i + 1){
        square = square + outs[j][i] * outs[j][i]
      }
      near(square / n, 1 / 3, 0.02)
    }
    assert(math.abs(alike(outs[0], outs[1])) < 0.04, string(alike(outs[0], outs[1])))
    assert(math.abs(alike(outs[0], outs[2])) < 0.04)
    assert(math.abs(alike(outs[1], outs[2])) < 0.04)
  }
}

t.group("the generated kernel"){
  t.test("constants fold"){
    local loop = loop_of(constants.source)
    assert(str.contains(loop, "out0[i] = 7.0"), loop)
    assert(str.contains(loop, "out1[i] = 0.5"), loop)
  }
  t.test("what depends only on controls is computed once a block"){
    local loop = loop_of(ratio.source)
    assert(not str.contains(loop, "ui_x"), loop)
    assert(
      str.contains(ratio.source, "local ui_x = clamp(d.ui_x, 0.0, 10.0)"),
      ratio.source,
    )
  }
  t.test("a slider smoothed once is one state, used three times"){
    // (each use of s applies the smoother again: the loops are the same
    // and become one)
    assert(count_of(smoothed.source, ": double,") == 1, smoothed.source)
    local y = run(smoothed, 4, {kernel.float:array({1, 1, 1, 1})})[0]
    local s = 0.5 * (1 - 0.999)
    near(y[0], s + s * s)
  }
  t.test("state lives in registers through the loop"){
    local loop = loop_of(onepole.source)
    assert(not str.contains(loop, "d."), loop)
  }
  t.test("x / c is a multiplication"){
    assert(not str.contains(loop_of(ratio.source), "/"))
  }
}

t.group("errors"){
  t.test("compositions that do not fit say why, at their line"){
    local e = error_of("x = 1;\nprocess = _ : (+, +);\n")
    assert(e.line == 2, string(e.line))
    assert(str.contains(
      e.message,
      "a : b needs as many outputs of a as inputs of b; a has 1 output, b 4 inputs",
    ), e.message)
    e = error_of("process = _, _ <: _, _, _;")
    assert(str.contains(e.message, "a <: b needs"), e.message)
    e = error_of("process = (_, _) ~ (_, _, _);")
    assert(str.contains(e.message, "a ~ b needs"), e.message)
  }
  t.test("unknown names, loops without ~, missing process"){
    assert(str.contains(error_of("process = foo;").message, "unknown name foo"))
    assert(str.contains(
      error_of("a = a : _;\nprocess = a;").message,
      "defined in terms of itself",
    ))
    assert(str.contains(error_of("x = 1;").message, "no process"))
  }
  t.test("a delay must be bounded"){
    local e = error_of("process = _, _ : @;")
    assert(str.contains(e.message, "a delay must be bounded"), e.message)
  }
  t.test("syntax errors"){
    local e = null
    try {
      grammar.parse("process = _ :;\n", "x.dsp")
    } catch(local err) {
      e = err
    }
    assert(e != null and e.line == 1)
  }
  t.test("a mistake in a dsp block is a compile error of the slang file"){
    local e = null
    try {
      compile(
        "extension \"dsp\"\nlocal a = 1\ndsp bad {\n  process = _ : (+, +);\n}\n",
        "bad.slang",
      )
    } catch(local err) {
      e = err
    }
    assert(e != null, "no error")
    assert(str.contains(e.message, "a : b needs"), e.message)
    assert(e.location.line == 4, string(e.location.line))
  }
  t.test("a mistake in an imported file names the file"){
    // (c1 = _ gives *(c1) two inputs inside std's conv2)
    local e = error_of("import \"std\";\nprocess = tf2(1, 0, 0, 0.5, _);\n")
    assert(str.ends_with(e.origin, "std.dsp"), string(e.origin))
    assert(str.contains(e.message, "a : b needs"), e.message)
  }
}

t.group("big programs"){
  t.test("every way of fitting the registers computes the same"){
    // a program with feedback, delay lines, controls and shared values
    local src = """
      import "std";
      f = hslider("f", 330, 50, 2000, 1);
      process = saw(f) : lowpass2(f * 3, 2) <: _, echo(0.01, 0.5) :> _ : *(adsr(0.001, 0.01, 0.5, 0.01, 1));
    """
    local r = build.program(grammar.parse(src, "big.dsp"), "big").signals
    local func render(options){
      local o = build.generate(r, "big", options)
      local m = kernel.compile(o.source, "big")
      local d = m.State:new({sr: 48000})
      local ring = kernel.float:array(math.max(o.info.ring, 1))
      local tmp = kernel.double:array(math.max(o.info.scratch, 1))
      local out = kernel.float:array(600)
      m.compute(d, ring, tmp, 600, out)
      return out
    }
    local want = render({})
    for(let local opts in values({
      {pool: true},
      {pool: true, spill_controls: true},
      {pool: true, spill_controls: true, spill_state: true},
      {
        pool: true, spill_controls: true, spill_state: true,
        spill_constants: true, constants: 3
      },
      {
        pool: true, spill_controls: true, spill_state: true,
        spill_constants: true
      },
      {pool: true, spill_controls: true, spill_state: true, registers: 2},
      {
        pool: true, spill_controls: true, spill_state: true,
        spill_constants: true, registers: 0
      },
    })){
      local got = render(opts)
      for(local i = 0; i < 600; i = i + 1){
        assert(
          got[i] == want[i],
          concat("sample ", string(i), " with ", string(opts)),
        )
      }
    }
  }
}

t.group("formatting and highlighting"){
  t.test("the library is formatted"){
    for(let local f in values({"std.dsp"})){
      local p = path.join(here, f)
      local text = os.read_file(p)
      assert(
        format.source(text, p, {find_project: true}) == text,
        concat(f, " is not formatted"),
      )
    }
  }
  t.test("a dsp block is laid out by the grammar's marks"){
    local messy = "extension \"dsp\"\ndsp x {\n    import \"std\" ;\n  f=hslider(\"f\",1,0,2,1);\n  process = osc(f)<:_,_;\n}\n"
    local want = "extension \"dsp\"\ndsp x {\n  import \"std\";\n  f = hslider(\"f\", 1, 0, 2, 1);\n  process = osc(f) <: _, _;\n}\n"
    local out = format.source(messy, path.join(here, "messy.slang"), {
      find_project: true,
    })
    assert(out == want, out)
  }
  t.test("a long chain breaks before each :"){
    local long = "extension \"dsp\"\ndsp x {\n  import \"std\";\n  process = saw(110) : lowpass2(800, 2) : *(adsr(0.01, 0.2, 0.5, 0.3, 1)) : drive(1.5) : *(0.5);\n}\n"
    local out = format.source(long, path.join(here, "long.slang"), {
      find_project: true,
    })
    assert(str.contains(
      out,
      "process = saw(110)\n    : lowpass2(800, 2)\n    : *(adsr",
    ), out)
  }
  t.test("tokens carry the language's categories"){
    local src = "extension \"dsp\"\ndsp x {\n  import \"std\";\n  g = button(\"gate\");\n  process = _ * g : mem;\n}\n"
    local h = compiler.highlight(src, path.join(here, "h.slang"), {
      find_project: true,
    })
    local cats = {}
    for(let local tk in values(h.tokens)){
      append(cats, concat(
        str.substring(src, tk.start, tk.start + tk.length), "=", tk.category
      ))
    }
    local all = str.join(cats, " ")
    for(let local want in values({
      "dsp=keyword",
      "x=variable.declaration",
      "import=keyword",
      "\"std\"=string",
      "g=function.declaration",
      "button=function.defaultLibrary",
      "_=variable.defaultLibrary",
      "*=operator",
      "mem=function.defaultLibrary",
      ":=operator",
    })){
      assert(str.contains(all, want), concat(want, " not in ", all))
    }
  }
}

