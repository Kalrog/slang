# Designing a filter

A biquad is the filter most audio is made of: two poles and two zeros,
five numbers. This notebook works out those numbers from what a filter
should do (the formulas of Robert Bristow-Johnson's *Audio EQ Cookbook*),
shows what the filter does to every frequency, plays it, and then
measures the filter the dsp package compiles, to check that it does what
the formulas say.

It needs a kernel on this machine: the dsp package compiles its programs
to kernels, and slang in a page has no `kernel` package.

## The formulas

`design` gives the coefficients of a filter of a kind at a frequency, as
the cookbook has them and divided through by `a0`:

    y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] - a1·y[n-1] - a2·y[n-2]

`q` is the resonance (0.707 is a flat, Butterworth lowpass) and `gain` is
in dB, for the peak and the shelves.

```slang
local nb = require("notebook")
local math = require("slang/math")

local SR = 48000
local KINDS = {"lowpass", "highpass", "bandpass", "notch", "peak", "low shelf", "high shelf"}

local func design(kind, freq, q, gain){
  local w = 2 * math.pi * freq / SR
  local cw = math.cos(w)
  local alpha = math.sin(w) / (2 * q)
  local A = math.exp(gain / 40 * math.log(10.0))
  local b = null
  local a = null
  if(kind == "lowpass"){
    b = {(1 - cw) / 2, 1 - cw, (1 - cw) / 2}
    a = {1 + alpha, -2 * cw, 1 - alpha}
  } else if(kind == "highpass"){
    b = {(1 + cw) / 2, -(1 + cw), (1 + cw) / 2}
    a = {1 + alpha, -2 * cw, 1 - alpha}
  } else if(kind == "bandpass"){
    b = {alpha, 0, -alpha}
    a = {1 + alpha, -2 * cw, 1 - alpha}
  } else if(kind == "notch"){
    b = {1, -2 * cw, 1}
    a = {1 + alpha, -2 * cw, 1 - alpha}
  } else if(kind == "peak"){
    b = {1 + alpha * A, -2 * cw, 1 - alpha * A}
    a = {1 + alpha / A, -2 * cw, 1 - alpha / A}
  } else {
    local s = 2 * math.sqrt(A) * alpha
    if(kind == "low shelf"){
      b = {
        A * ((A + 1) - (A - 1) * cw + s), 2 * A * ((A - 1) - (A + 1) * cw),
        A * ((A + 1) - (A - 1) * cw - s)
      }
      a = {(A + 1) + (A - 1) * cw + s, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - s}
    } else {
      b = {
        A * ((A + 1) + (A - 1) * cw + s), -2 * A * ((A - 1) + (A + 1) * cw),
        A * ((A + 1) + (A - 1) * cw - s)
      }
      a = {(A + 1) - (A - 1) * cw + s, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - s}
    }
  }
  return {
    b0: b[0] / a[0], b1: b[1] / a[0], b2: b[2] / a[0], a1: a[1] / a[0],
    a2: a[2] / a[0]
  }
}

design("lowpass", 1000, 0.707, 0)
```

What the filter does to a sine of frequency `f`: the coefficients give
`H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)` at `z = e^(iω)`.
Its size is the gain (in dB), its angle how far the sine is shifted.

```slang
local func response(c, f){
  local w = 2 * math.pi * f / SR
  local c1 = math.cos(w)
  local s1 = math.sin(w)
  local c2 = math.cos(2 * w)
  local s2 = math.sin(2 * w)
  local nr = c.b0 + c.b1 * c1 + c.b2 * c2
  local ni = -(c.b1 * s1 + c.b2 * s2)
  local dr = 1 + c.a1 * c1 + c.a2 * c2
  local di = -(c.a1 * s1 + c.a2 * s2)
  local magnitude = math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di))
  local phase = math.atan2(ni, nr) - math.atan2(di, dr)
  for(phase > math.pi){
    phase = phase - 2 * math.pi
  }
  for(phase < -math.pi){
    phase = phase + 2 * math.pi
  }
  return {db: 20 * math.log10(math.max(magnitude, 1e-12)), degrees: phase * 180 / math.pi}
}

// the poles: the roots of z² + a1·z + a2. The filter is stable when both
// are inside the unit circle
local func poles(c){
  local disc = c.a1 * c.a1 - 4 * c.a2
  if(disc < 0){
    local r = math.sqrt(c.a2)
    return {radius: r, angle: math.acos(math.max(-1, math.min(1, -c.a1 / (2 * r))))}
  }
  local r1 = math.abs((-c.a1 + math.sqrt(disc)) / 2)
  local r2 = math.abs((-c.a1 - math.sqrt(disc)) / 2)
  return {radius: math.max(r1, r2), angle: 0}
}

response(design("lowpass", 1000, 0.707, 0), 1000)
```

## Drawing it

A chart with frequency on a log axis, from 20 Hz to 20 kHz, as SVG made
with slang's HTML templates. `lines` are curves (lists of `{f, y}`), and
`dots` are measured points.

```slang
extension "extensions/html"
local html = require("slang/html")
local str = require("slang/string")
local tbl = require("slang/table")

local W = 640
local H = 230
local LEFT = 46
local RIGHT = 12
local TOP = 22
local BOTTOM = 26
local F_LO = math.log10(20.0)
local F_HI = math.log10(20000.0)

local func chart(options){
  local y_lo = options.y_min
  local y_hi = options.y_max
  local func x_of(f){
    return LEFT + (math.log10(f) - F_LO) / (F_HI - F_LO) * (W - LEFT - RIGHT)
  }
  local func y_of(y){
    y = math.max(y_lo, math.min(y_hi, y))
    return TOP + (y_hi - y) / (y_hi - y_lo) * (H - TOP - BOTTOM)
  }
  local grid = {}
  for(let local f in values({20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000})){
    local label = f >= 1000 and concat(string(to_int(f / 1000)), "k") or string(f)
    append(grid, <g>
      <line x1={string(x_of(f))} x2={string(x_of(f))} y1={string(TOP)} y2={string(H - BOTTOM)}
        stroke="var(--nb-line)" stroke-width="1"/>
      <text x={string(x_of(f))} y={string(H - 8)} text-anchor="middle">{label}</text>
    </g>)
  }
  for(local y = y_lo; y <= y_hi; y = y + options.y_step){
    append(grid, <g>
      <line x1={string(LEFT)} x2={string(W - RIGHT)} y1={string(y_of(y))} y2={string(y_of(y))}
        stroke="var(--nb-line)" stroke-width={y == 0 and "2" or "1"}/>
      <text x={string(LEFT - 6)} y={string(y_of(y) + 4)} text-anchor="end">{string(y)}</text>
    </g>)
  }
  local curves = {}
  for(let local line in values(options.lines or {})){
    local parts = {}
    for(let local p in values(line.points)){
      append(parts, concat(len(parts) == 0 and "M" or "L", string(x_of(p.f)), " ", string(y_of(p.y))))
    }
    append(curves, <path d={str.join(parts, "")} fill="none" stroke={line.color}
      stroke-width="2.2" stroke-linejoin="round"/>)
  }
  for(let local p in values(options.dots or {})){
    append(curves, <circle cx={string(x_of(p.f))} cy={string(y_of(p.y))} r="2.2"
      fill="var(--nb-function)"/>)
  }
  for(let local f in values(options.marks or {})){
    append(curves, <line x1={string(x_of(f))} x2={string(x_of(f))} y1={string(TOP)}
      y2={string(H - BOTTOM)} stroke="var(--nb-accent)" stroke-dasharray="4 3"/>)
  }
  return <svg viewBox={concat("0 0 ", string(W), " ", string(H))} width={string(W)}
    style="max-width: 100%; height: auto; font: 11px var(--nb-mono); fill: var(--nb-muted)">
    <text x={string(LEFT)} y="12" style="fill: var(--nb-ink)">{options.title}</text>
    {grid}
    {curves}
  </svg>
}

// frequencies from 20 Hz to 20 kHz, n of them, evenly on the log axis
local func sweep(n){
  local out = {}
  for(local i = 0; i < n; i = i + 1){
    append(out, math.exp(math.log(20.0) + i / (n - 1) * math.log(1000.0)))
  }
  return out
}

local FREQS = sweep(240)

local func plots(c, options){
  options = options or {}
  local gain = {}
  local phase = {}
  for(let local f in values(FREQS)){
    local r = response(c, f)
    append(gain, {f: f, y: r.db})
    append(phase, {f: f, y: r.degrees})
  }
  return <div>
    {chart({
      title: "gain (dB)", y_min: -48, y_max: 24, y_step: 12,
      lines: {{points: gain, color: "var(--nb-accent)"}}, dots: options.dots,
      marks: options.marks
    })}
    {chart({
      title: "phase (degrees)", y_min: -180, y_max: 180, y_step: 90,
      lines: {{points: phase, color: "var(--nb-keyword)"}}, marks: options.marks
    })}
  </div>
}

nb.html(plots(design("lowpass", 1000, 0.707, 0), {marks: {1000}}))
```

## Trying it out

The controls set the kind, the frequency (on a log scale, as hearing
has it), the resonance and the gain. Under them: the response, the five
numbers, and where the poles are. A pole outside the unit circle makes a
filter that blows up.

```slang
local kind = nb.dropdown({label: "kind", options: KINDS, value: "lowpass"})
local freq = nb.slider({label: "frequency", min: 20.0, max: 20000.0, value: 1000.0, scale: "log"})
local q = nb.slider({label: "Q", min: 0.1, max: 30.0, value: 0.707, scale: "log"})
local gain = nb.slider({label: "gain (dB)", min: -24.0, max: 24.0, value: 6.0, step: 0.5})

// the filter the controls describe now
local func current(){
  return design(kind.value, freq.value, q.value, gain.value)
}

local func summary(c){
  local p = poles(c)
  local stable = p.radius < 1
  return <div style="display: flex; gap: 28px; flex-wrap: wrap; font: 12.5px var(--nb-mono)">
    <table class="nb-table">
      <tbody>
        {tbl.map({"b0", "b1", "b2", "a1", "a2"}, func(k){
          return <tr><td>{k}</td><td class="num">{str.format("%.6f", c[k])}</td></tr>
        })}
      </tbody>
    </table>
    <div>
      <div>poles at radius {str.format("%.5f", p.radius)}, angle {str.format("%.1f", p.angle * SR / (2 * math.pi))} Hz</div>
      <div style={concat("color: var(", stable and "--nb-ok" or "--nb-error", ")")}>
        {stable and "stable" or "unstable: it grows without end"}
      </div>
      <div style="color: var(--nb-muted)">gain at {str.format("%.0f", freq.value)} Hz: {str.format("%.2f", response(c, freq.value).db)} dB</div>
    </div>
  </div>
}

nb.interact({kind: kind, freq: freq, q: q, gain: gain}, func(v){
  local c = current()
  return nb.html(<div>
    {plots(c, {marks: {freq.value}})}
    {summary(c)}
  </div>)
})
```

## Listening

The same filter as a dsp program: `tf2` of std.dsp is a biquad of five
coefficients, and here they are controls, so slang sets them from
`design`. A second program makes something to filter.

```slang
local kernel = require("kernel")

dsp biquad {
  import "std";
  b0 = hslider("b0", 1, -64, 64, 0.000001);
  b1 = hslider("b1", 0, -64, 64, 0.000001);
  b2 = hslider("b2", 0, -64, 64, 0.000001);
  a1 = hslider("a1", 0, -2, 2, 0.000001);
  a2 = hslider("a2", 0, -1, 1, 0.000001);
  process = tf2(b0, b1, b2, a1, a2);
}

dsp source {
  import "std";
  which = nentry("which", 0, 0, 2, 1);
  freq = hslider("freq", 110, 20, 2000, 0.01);
  process = select3(which, noise * 0.3, saw(freq) * 0.3, square(freq) * 0.3);
}

local SOURCES = {"noise", "saw", "square"}

// n samples of x through a filter with the coefficients c
local func run(c, x){
  local f = biquad:new({sample_rate: SR})
  for(let local k in values({"b0", "b1", "b2", "a1", "a2"})){
    f[k] = c[k]
  }
  local y = kernel.float:array(len(x))
  f:compute(len(x), {x}, {y})
  return y
}

local func render(what, seconds){
  local s = source:new({sample_rate: SR})
  s.which = tbl.index_of(SOURCES, what)
  local x = kernel.float:array(to_int(seconds * SR))
  s:compute(len(x), {}, {x})
  return x
}

local func peak(x){
  local p = 0.0
  for(local i = 0; i < len(x); i = i + 1){
    p = math.max(p, math.abs(x[i]))
  }
  return p
}

local what = nb.dropdown({label: "sound", options: SOURCES})
// (the output goes under the controls; the button's function finds it here)
local heard = null
nb.display(nb.panel({what, nb.button("Listen", func(){
  local c = current()
  if(poles(c).radius >= 1){
    heard:show(nb.text("This filter is unstable: nothing to hear."))
    return
  }
  local dry = render(what.value, 2)
  local wet = run(c, dry)
  // a boost can clip: then the filtered sound is turned down to fit
  local p = peak(wet)
  local note = "as it is"
  if(p > 0.95){
    local scale = 0.95 / p
    for(local i = 0; i < len(wet); i = i + 1){
      wet[i] = wet[i] * scale
    }
    note = str.format("turned down %.1f dB to fit", 20 * math.log10(1 / scale))
  }
  heard:show(
    nb.markdown(concat("**dry** ", what.value)), nb.audio(dry, {rate: SR}),
    nb.markdown(concat("**", kind.value, "** at ", str.format("%.0f", freq.value), " Hz, ", note)),
    nb.audio(wet, {rate: SR}),
  )
})}))
heard = nb.output()
```

## Is the compiled filter the designed one?

White noise goes through the compiled filter, and the response is
measured from what comes out: the spectrum of the output over that of
the input, averaged over many windows of 4096 samples (Welch's method,
with an FFT written here). The dots are the measurement, the line is
the formula. They should lie on each other.

```slang
local N = 4096

// an FFT of re and im in place (len a power of 2)
local tw_re = {}
local tw_im = {}
for(local k = 0; k < N / 2; k = k + 1){
  append(tw_re, math.cos(2 * math.pi * k / N))
  append(tw_im, -math.sin(2 * math.pi * k / N))
}

local func fft(re, im){
  local n = len(re)
  local j = 0
  for(local i = 1; i < n; i = i + 1){
    local bit = n >> 1
    for((j & bit) != 0){
      j = j - bit
      bit = bit >> 1
    }
    j = j + bit
    if(i < j){
      local t = re[i]
      re[i] = re[j]
      re[j] = t
      t = im[i]
      im[i] = im[j]
      im[j] = t
    }
  }
  local size = 2
  for(size <= n){
    local half = size >> 1
    // (/ makes a double: an index has to be an int)
    local stride = to_int(n / size)
    for(local start = 0; start < n; start = start + size){
      for(local k = 0; k < half; k = k + 1){
        local wr = tw_re[k * stride]
        local wi = tw_im[k * stride]
        local a = start + k
        local b = a + half
        local xr = re[b] * wr - im[b] * wi
        local xi = re[b] * wi + im[b] * wr
        re[b] = re[a] - xr
        im[b] = im[a] - xi
        re[a] = re[a] + xr
        im[a] = im[a] + xi
      }
    }
    size = size * 2
  }
}

local window = {}
for(local i = 0; i < N; i = i + 1){
  append(window, 0.5 - 0.5 * math.cos(2 * math.pi * i / N))
}

// |H| at every bin, from the cross spectrum of x and y over their own
local func measure(x, y){
  local sxy_re = {}
  local sxy_im = {}
  local sxx = {}
  for(local k = 0; k <= N / 2; k = k + 1){
    append(sxy_re, 0.0)
    append(sxy_im, 0.0)
    append(sxx, 0.0)
  }
  for(local at = 0; at + N <= len(x); at = at + (N >> 1)){
    local xr = {}
    local xi = {}
    local yr = {}
    local yi = {}
    for(local i = 0; i < N; i = i + 1){
      append(xr, x[at + i] * window[i])
      append(xi, 0.0)
      append(yr, y[at + i] * window[i])
      append(yi, 0.0)
    }
    fft(xr, xi)
    fft(yr, yi)
    for(local k = 0; k <= N / 2; k = k + 1){
      // Y times the conjugate of X
      sxy_re[k] = sxy_re[k] + yr[k] * xr[k] + yi[k] * xi[k]
      sxy_im[k] = sxy_im[k] + yi[k] * xr[k] - yr[k] * xi[k]
      sxx[k] = sxx[k] + xr[k] * xr[k] + xi[k] * xi[k]
    }
  }
  local out = {}
  for(local k = 0; k <= N / 2; k = k + 1){
    append(out, math.sqrt(sxy_re[k] * sxy_re[k] + sxy_im[k] * sxy_im[k]) / math.max(sxx[k], 1e-30))
  }
  return out
}

local func check(){
  local c = current()
  if(poles(c).radius >= 1){
    return nb.text("This filter is unstable: there is nothing to measure.")
  }
  local started = require("slang/time").clock()
  local x = render("noise", N * 16 / SR)
  local h = measure(x, run(c, x))
  // dots at about 120 frequencies, evenly on the log axis; the worst
  // difference from the formula where the filter lets something through
  local dots = {}
  local worst = 0.0
  local shown = -1
  for(let local f in values(sweep(120))){
    local k = to_int(f * N / SR + 0.5)
    if(k > shown and k > 0 and k < N / 2){
      shown = k
      local bin = k * SR / N
      local db = 20 * math.log10(math.max(h[k], 1e-12))
      append(dots, {f: bin, y: db})
      local expected = response(c, bin).db
      if(bin >= 40 and bin <= 16000 and expected > -40){
        worst = math.max(worst, math.abs(db - expected))
      }
    }
  }
  local ms = require("slang/time").clock() - started
  return nb.html(<div>
    {plots(c, {dots: dots, marks: {freq.value}})}
    <div style="font: 12.5px var(--nb-mono)">
      measured from {string(len(x))} samples of noise in {str.format("%.0f", ms)} ms:
      at most {str.format("%.2f", worst)} dB from the formula, from 40 Hz to 16 kHz
    </div>
  </div>)
}

local measured = nb.output(check())
nb.button("Measure again", func(){ measured:show(check()) })
```

## And std.dsp's own filters?

std.dsp has a lowpass, a highpass and a bandpass of its own, written in
the dsp language from the same cookbook. Given the same frequency and Q,
they should make the same samples as `design`'s coefficients do: here
the first 4096 samples of each one's answer to a click.

```slang
dsp std_filters {
  import "std";
  which = nentry("which", 0, 0, 2, 1);
  fc = hslider("fc", 1000, 20, 20000, 0.000001);
  q = hslider("q", 0.707, 0.1, 30, 0.000001);
  // (select3(which) after the filters would take which as its last input:
  // a box applied to fewer signals gets them on its last inputs)
  process = \(x).(select3(which, x : lowpass2(fc, q), x : highpass2(fc, q), x : bandpass2(fc, q)));
}

local func compare(){
  local click = kernel.float:array(4096)
  click[0] = 1
  local rows = {}
  for(local i = 0; i < 3; i = i + 1){
    local name = KINDS[i]
    local s = std_filters:new({sample_rate: SR})
    s.which = i
    s.fc = freq.value
    s.q = q.value
    local theirs = kernel.float:array(4096)
    s:compute(4096, {click}, {theirs})
    local ours = run(design(name, freq.value, q.value, 0), click)
    local diff = 0.0
    for(local n = 0; n < 4096; n = n + 1){
      diff = math.max(diff, math.abs(theirs[n] - ours[n]))
    }
    append(rows, {
      filter: name, at: str.format("%.1f Hz, Q %.3f", freq.value, q.value),
      ["largest difference"]: str.format("%.2e", diff),
      ["the same"]: diff < 1e-5 and "yes" or "no"
    })
  }
  return nb.table(rows)
}

local compared = nb.output(compare())
nb.button("Compare again", func(){ compared:show(compare()) })
```
