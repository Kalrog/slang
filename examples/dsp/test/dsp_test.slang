local t = require("slang/test")
local str = require("slang/string")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local kernel = require("kernel")
local format = require("slang/format")

// The example without a window or an audio device: the car's engine and
// what a listener hears of it, and the player's engine with every
// instrument. (The language's own tests are the package's:
// packages/dsp/test.)

local here = __PACKAGES.search_paths[0]

local func near(a, b, eps, message){
  assert(math.abs(a - b) <= (eps or 1e-5), concat(
    message or "", " expected ", string(b), ", got ", string(a)
  ))
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

t.group("formatting"){
  t.test("the example's files are formatted"){
    for(let local f in values({
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
