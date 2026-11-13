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

// The dsp language without a window or an audio device: what programs
// compute (against the same thing written in slang), what the compiler
// makes of them, its errors, formatting and highlighting, and the
// player's engine with every instrument.

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

dsp biquad {
  import "std";
  process = lowpass2(1000, 2);
}

dsp constants {
  process = 2 * 3 + 1, sin(0) + 0.5;
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

t.group("the engine (programs/inline4.dsp)"){
  local inline4 = require("programs/inline4")
  local func drive(v, seconds, throttle, each){
    v.throttle = throttle
    local outs = {}
    for(local j = 0; j < inline4.outputs; j = j + 1){
      append(outs, kernel.float:array(256))
    }
    for(local b = 0; b < to_int(seconds * 48000 / 256); b = b + 1){
      v:compute(256, {}, outs)
      if(each != null){
        each(outs)
      }
    }
    return outs
  }
  t.test("it idles, revs to the limiter and back"){
    local v = inline4:new()
    local outs = drive(v, 3, 0)
    near(outs[4][255], 800, 60, "idle rpm")
    local top = 0.0
    local low_after_top = 9999.0
    drive(v, 2.5, 1, func(o){
      top = math.max(top, o[4][255])
      if(top > 6700){
        low_after_top = math.min(low_after_top, o[4][255])
      }
    })
    assert(top > 6700 and top < 6900, concat("top ", string(top)))
    // the limiter cuts and lets go: the rpm bounces below the limit
    assert(low_after_top < 6650, concat("no bounce: ", string(low_after_top)))
    outs = drive(v, 3, 0)
    near(outs[4][255], 800, 100, "back to idle")
  }
  t.test("cylinder 1 peaks after top dead centre, harder at full throttle"){
    local func peak_of(throttle){
      local v = inline4:new()
      drive(v, 2, throttle)
      local peak = 0.0
      local at = 0.0
      drive(v, 0.2, throttle, func(o){
        for(local i = 0; i < 256; i = i + 1){
          if(o[5][i] > peak){
            peak = o[5][i]
            at = o[6][i]
          }
        }
      })
      return {peak, at}
    }
    local idle = peak_of(0)
    local full = peak_of(1)
    // (bar above an atmosphere; the firing top dead centre is at 0.5)
    assert(idle[0] > 5 and idle[0] < 20, concat("idle peak ", string(idle[0])))
    assert(full[0] > 30 and full[0] < 80, concat("full peak ", string(full[0])))
    assert(
      full[1] > 0.5 and full[1] < 0.5 + 30 / 720,
      concat("peak at ", string(full[1] * 720), " degrees"),
    )
  }
  t.test("the exhaust sounds at the firing frequency's harmonics"){
    local v = inline4:new()
    drive(v, 3, 0)
    local n = 24000
    local x = kernel.float:array(n)
    local rpm = 0.0
    local k = 0
    drive(v, n / 48000, 0, func(o){
      for(local i = 0; i < 256; i = i + 1){
        x[k] = o[0][i]
        k = k + 1
      }
      rpm = o[4][255]
    })
    // a four-cylinder four-stroke fires twice a turn
    local f0 = rpm / 30
    local func mag(f){
      local re = 0.0
      local im = 0.0
      for(local i = 0; i < n; i = i + 1){
        re = re + x[i] * math.cos(2 * math.pi * f * i / 48000)
        im = im + x[i] * math.sin(2 * math.pi * f * i / 48000)
      }
      return math.sqrt(re * re + im * im) / n
    }
    local orders = mag(f0) + mag(2 * f0) + mag(3 * f0)
    local halves = mag(0.5 * f0) + mag(1.5 * f0) + mag(2.5 * f0)
    assert(orders > 2 * halves, concat(string(orders), " vs ", string(halves)))
  }
  t.test("in gear the car's speed follows the revs"){
    local v = inline4:new()
    v.gear = 1
    local outs = drive(v, 4, 0.5)
    local rpm = outs[4][255]
    local kmh = outs[8][255]
    // the clutch grips: wheels turn at rpm over both ratios
    local expect = rpm / 60 * 2 * math.pi / (3.5 * 4.1) * 0.31 * 3.6
    near(kmh, expect, expect * 0.03, "km/h")
    // (from a standstill with the clutch in, the engine lugs: slowly)
    assert(kmh > 10, concat("km/h ", string(kmh)))
  }
  t.test("the driver pulls away, shifts up, and stops"){
    local v = inline4:new()
    local driver = require("driver").new({automatic: true})
    local rpm = 0.0
    local kmh = 0.0
    local top_gear = 0
    local func run(seconds){
      drive(v, 0, 0)
      for(local b = 0; b < to_int(seconds * 48000 / 256); b = b + 1){
        local c = driver:step(256 / 48000, rpm, kmh)
        v.throttle = c.throttle
        v.clutch = c.clutch
        v.gear = c.gear
        v.brake = c.brake
        local outs = drive(v, 256 / 48000, c.throttle)
        rpm = outs[4][255]
        kmh = outs[8][255]
        top_gear = math.max(top_gear, c.gear)
      }
    }
    run(1)
    driver.pedal = 1
    run(7)
    assert(
      kmh > 50 and top_gear >= 2,
      concat(string(kmh), " km/h in ", string(top_gear)),
    )
    driver.pedal = 0
    driver.brake = 1
    run(3)
    assert(kmh < 1, concat("still ", string(kmh), " km/h"))
    // the clutch opens as the car stops: the engine idles
    run(1)
    assert(rpm > 600, concat("stalled at ", string(rpm)))
  }
  t.test("it keeps up with the audio rate, with room to spare"){
    // the whole car (engine and acoustics, vehicle.slang) in blocks of
    // 128 at 48 kHz: 2.67 ms each to compute in. It takes some 9% of that;
    // the test allows a slow or busy machine (and checked builds) a lot
    // more, but no block may take a whole budget.
    local vehicle = require("vehicle")
    local car = vehicle.new({block: 128})
    car:set("throttle", 1)
    car:set("gear", 2)
    local time = require("slang/time")
    local budget = 128 / 48.0
    local total = 0.0
    local worst = 0.0
    local blocks = 750
    for(local b = 0; b < blocks; b = b + 1){
      local t0 = time.clock()
      car:compute(128)
      local dt = time.clock() - t0
      total = total + dt
      worst = math.max(worst, dt)
    }
    local load = total / blocks / budget
    assert(load < 0.5, concat("mean load ", string(load)))
    assert(worst < budget, concat("a block took ", string(worst), " ms"))
  }
  t.test("it is too big for the registers, and fits all the same"){
    // (the state and constants it keeps in the instance)
    assert(str.contains(inline4.source, "d.m"))
    assert(len(inline4.controls) == 13)
  }
}

t.group("what you hear (programs/acoustics.dsp)"){
  local acoustics = require("programs/acoustics")
  local N = 4800
  // one second of the left channel (after half a second to settle): the
  // car at kmh, the exhaust stem from exhaust(i) (null: silent), the
  // controls as settings say
  local func listen(kmh, settings, exhaust){
    local v = acoustics:new()
    for(let local e in entries(settings)){
      v:set(e[0], e[1])
    }
    local stems = {}
    for(local j = 0; j < 4; j = j + 1){
      append(stems, kernel.float:array(N))
    }
    local speed = kernel.float:array(N)
    for(local i = 0; i < N; i = i + 1){
      speed[i] = kmh
    }
    append(stems, speed)
    local left = kernel.float:array(N)
    local right = kernel.float:array(N)
    local out = kernel.float:array(N * 10)
    for(local b = 0; b < 15; b = b + 1){
      if(exhaust != null){
        for(local i = 0; i < N; i = i + 1){
          stems[0][i] = exhaust(b * N + i)
        }
      }
      v:compute(N, stems, {left, right})
      if(b >= 5){
        for(local i = 0; i < N; i = i + 1){
          out[(b - 5) * N + i] = left[i]
        }
      }
    }
    return out
  }
  local func rms_db(x){
    local s = 0.0
    for(local i = 0; i < len(x); i = i + 1){
      s = s + x[i] * x[i]
    }
    return 10 * math.log10(s / len(x) + 1e-30)
  }
  // the share of x's power above some 2 kHz (its first difference's
  // power against its own), in dB
  local func highs_db(x){
    local d = kernel.float:array(len(x))
    for(local i = 1; i < len(x); i = i + 1){
      d[i] = x[i] - x[i - 1]
    }
    return rms_db(d) - rms_db(x)
  }
  t.test("a car standing still with its engine off is silent"){
    assert(rms_db(listen(0, {})) < -150)
    assert(rms_db(listen(0, {listener: 1})) < -150)
  }
  t.test("the tyres grow louder with speed"){
    local slow = rms_db(listen(50, {["wind level"]: 0}))
    local fast = rms_db(listen(100, {["wind level"]: 0}))
    // (real tyres: some 10 dB from 50 to 100 km/h)
    assert(
      fast - slow > 6 and fast - slow < 20,
      concat(string(slow), " -> ", string(fast)),
    )
  }
  t.test("the wind grows with the cube of the speed"){
    local slow = rms_db(listen(60, {["tyre level"]: 0}))
    local fast = rms_db(listen(120, {["tyre level"]: 0}))
    // twice the speed: 2^3 the pressure, 18 dB
    near(fast - slow, 18, 4, "dB")
  }
  t.test("cobbles are louder than asphalt"){
    local smooth = rms_db(listen(30, {["wind level"]: 0}))
    local cobbles = rms_db(listen(30, {["wind level"]: 0, road: 2}))
    assert(
      cobbles - smooth > 3,
      concat(string(smooth), " vs ", string(cobbles)),
    )
  }
  t.test("the cabin keeps out the highs"){
    // a noisy exhaust, heard outside and inside
    local seed = 12345
    local func noise(i){
      seed = (seed * 69069 + 1) % 4294967296
      return seed / 4294967296.0 - 0.5
    }
    local outside = highs_db(listen(0, {}, noise))
    local inside = highs_db(listen(0, {listener: 1}, noise))
    assert(
      outside - inside > 20,
      concat(string(outside), " vs ", string(inside)),
    )
  }
}

// ------------------------------------------------------------ tools

t.group("formatting and highlighting"){
  t.test("the example's files are formatted"){
    for(let local f in values({
      "std.dsp",
      "programs/stereo_reverb.dsp",
      "programs/inline4.dsp",
      "programs/acoustics.dsp",
      "instruments.slang",
      "engine.slang",
      "main.slang",
      "car.slang",
      "driver.slang",
      "vehicle.slang",
      "tool/drive.slang",
      "tool/spectrum.slang",
      "tool/realtime.slang",
    })){
      local p = path.join(here, f)
      local text = os.read_file(p)
      assert(
        format.source(text, p, {find_project: true}) == text,
        concat(f, " is not formatted"),
      )
    }
  }
  t.test("a dsp block is laid out by the grammar's marks"){
    local messy = "dsp x {\n    import \"std\" ;\n  f=hslider(\"f\",1,0,2,1);\n  process = osc(f)<:_,_;\n}\n"
    local want = "dsp x {\n  import \"std\";\n  f = hslider(\"f\", 1, 0, 2, 1);\n  process = osc(f) <: _, _;\n}\n"
    local out = format.source(messy, path.join(here, "messy.slang"), {
      find_project: true,
    })
    assert(out == want, out)
  }
  t.test("a long chain breaks before each :"){
    local long = "dsp x {\n  import \"std\";\n  process = saw(110) : lowpass2(800, 2) : *(adsr(0.01, 0.2, 0.5, 0.3, 1)) : drive(1.5) : *(0.5);\n}\n"
    local out = format.source(long, path.join(here, "long.slang"), {
      find_project: true,
    })
    assert(str.contains(
      out,
      "process = saw(110)\n    : lowpass2(800, 2)\n    : *(adsr",
    ), out)
  }
  t.test("tokens carry the language's categories"){
    local src = "dsp x {\n  import \"std\";\n  g = button(\"gate\");\n  process = _ * g : mem;\n}\n"
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

t.group("the player's engine"){
  t.test("every instrument sounds through the echo and the reverb"){
    local engine = require("engine")
    local instruments = require("instruments")
    local layout = engine.layout()
    for(local k = 0; k < len(instruments.list); k = k + 1){
      local params = engine.params(layout)
      params[engine.PROGRAM] = k
      params[engine.FREQ] = 330
      params[engine.GATE] = 1
      local block = engine.new(params, 48000)
      local out = kernel.float:array(256)
      local peak = 0.0
      for(local b = 0; b < 40; b = b + 1){
        block(out, 128)
        for(local i = 0; i < 256; i = i + 1){
          local v = math.abs(out[i])
          assert(not math.is_nan(v), concat(instruments.names[k], " made NaN"))
          peak = math.max(peak, v)
        }
      }
      assert(
        peak > 0.02 and peak < 1.5,
        concat(instruments.names[k], " peak ", string(peak)),
      )
    }
  }
}
