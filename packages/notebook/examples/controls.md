# Controls

A cell can show controls (sliders, checkboxes, dropdowns, inputs and
buttons) whose functions run in the kernel when they change, with the
cells' locals. An output made with `nb.output` is a place under the cell
that those functions fill again.

Run the cells first: a control works while the kernel that made it runs,
and is greyed out after a restart until its cell runs again.

## A slider and a plot

`nb.interact` shows controls, and under them what a function gives for
their values, again each time one of them changes.

```slang
local nb = require("notebook")
local math = require("slang/math")

local func wave(frequency, damping){
  local ys = {}
  for(local i = 0; i < 400; i = i + 1){
    local t = i / 100
    append(ys, math.sin(t * frequency) * math.exp(-t * damping))
  }
  return ys
}

nb.interact({
  frequency: nb.slider({min: 1.0, max: 20.0, value: 6.0}),
  damping: nb.slider({min: 0.0, max: 2.0, value: 0.5}),
}, func(v){
  return nb.plot(wave(v.frequency, v.damping), {
    title: "A damped wave", height: 220, y_min: -1, y_max: 1
  })
})
```

## Controls of your own making

A control's function is called with its new value. Here they fill an
output, and a control's `value` is what it is set to now, for the cells
after it too.

```slang
local shape = nb.dropdown({label: "shape", options: {"square", "circle", "diamond"}})
local size = nb.slider({label: "size", min: 10, max: 90, value: 50})
local filled = nb.checkbox({label: "filled", value: true})
local caption = nb.input({label: "caption", value: "a shape"})

local func picture(){
  local s = size.value
  local fill = filled.value and "#e8472a" or "none"
  local mark = concat("<rect x='", string(100 - s), "' y='", string(100 - s),
    "' width='", string(2 * s), "' height='", string(2 * s), "'")
  if(shape.value == "circle"){
    mark = concat("<circle cx='100' cy='100' r='", string(s), "'")
  } else if(shape.value == "diamond"){
    mark = concat("<polygon points='100,", string(100 - s), " ", string(100 + s),
      ",100 100,", string(100 + s), " ", string(100 - s), ",100'")
  }
  return nb.svg(concat(
    "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='200' viewBox='0 0 200 200'>",
    mark, " fill='", fill, "' stroke='#e8472a' stroke-width='3'/>",
    "<text x='100' y='196' text-anchor='middle' font-size='13' fill='currentColor'>",
    caption.value, "</text></svg>"
  ))
}

nb.display(nb.panel({shape, size, filled, caption}))
local view = nb.output(picture())
for(let local c in values({shape, size, filled, caption})){
  c.on_change = func(v){ view:show(picture()) }
}
```

A button calls its function with each click:

```slang
local rolls = {}
local dice = nb.output("no rolls yet")
nb.display(nb.button("Roll", func(){
  append(rolls, math.random_int(1, 6))
  dice:show(concat("rolled ", string(rolls[len(rolls) - 1]), ", ", string(len(rolls)), " rolls so far"))
}))
```

```slang
rolls
```

## From your own HTML

`nb.on` names a function that a script in a cell's HTML calls with
`slang.call(name, value)`: a promise of what it gives back.

```slang
nb.on("factor", func(n){
  local out = {}
  local d = 2
  for(n > 1 and d <= n){
    if(n % d == 0){
      append(out, d)
      n = to_int(n / d)
    } else {
      d = d + 1
    }
  }
  return out
})

nb.html("""
<input id="nb-n" type="number" value="360" style="width: 8em">
<button onclick="slang.call('factor', Number(document.getElementById('nb-n').value))
  .then(f => document.getElementById('nb-f').textContent = f.join(' × '))
  .catch(e => document.getElementById('nb-f').textContent = e.message)">Factor</button>
<span id="nb-f"></span>
""")
```
