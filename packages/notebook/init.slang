extension "extensions/html"
// notebook: what the cells of a notebook call to show something richer
// than text.
//
//   local nb = require("notebook")
//   nb.plot({1, 4, 9, 16}, {title: "squares"})      // a cell's last line
//   nb.display(nb.markdown("**done**"), nb.table(rows))   // or anywhere
//
// A notebook is a Markdown file whose ```slang blocks are cells, run with
// `slang notebook` or in the browser with `slang notebook-server`. A cell
// shows what it prints and the value it ends in: tables as trees to
// unfold, and a [Display] as what it is, HTML, an image, a plot, sound.
// [display] shows values from the middle of a cell.
//
// A value of your own shows itself with `__display` in its metatable, a
// function of the value that gives a Display (or any other value to show
// in its place):
//
//   Matrix.@meta = {__display: func(m){ return nb.table(m.rows) }}
//
// Outside a notebook the same calls print text, so a module that uses them
// also runs as a plain program.
local str = require("slang/string")
local os = require("slang/os")
local math = require("slang/math")
local encoding = require("slang/encoding")
local html = require("slang/html")
local tbl = require("slang/table")
local inspect = require("notebook/inspect")

local nb = {}

// Something to show, in one or more forms: the page takes the richest it
// knows, a terminal the text. Made by [html], [markdown], [svg], [image],
// [table], [plot], [audio] and [text].
// type Display = {data: {[string]: any}}
// [data]: the forms by MIME type ("text/plain", "text/html", ...)
local display_meta = {__type: "notebook.Display"}

// the mime type of a value's tree (notebook/inspect)
local VALUE = "application/vnd.slang.value+json"

local func make(data){
  local d = {data: data}
  d.@meta = display_meta
  return d
}

// where displays go while a kernel runs the code: sink(kind, data)
local sink = null

// attach(f?: func(kind: string, data: table?))
// Sends what [display] and [clear] show to f from now on (null: back to
// printing): kind is "display" with a [Display]'s data, or "clear". The
// notebook's kernel calls it; a program has no reason to.
func nb.attach(f){
  sink = f
}

// in_notebook() -> bool
// Whether the code runs in a notebook's kernel.
func nb.in_notebook(){
  return sink != null
}

// ------------------------------------------------------------ displays

// text(s: string) -> Display
// s as it is, where a string as a value would be shown in quotes.
func nb.text(s){
  return make({["text/plain"]: string(s)})
}

// html(content: string | html.Node) -> Display
// HTML, put into the page as it is: markup, styles and scripts of yours.
func nb.html(content){
  if(type(content) != "string"){
    content = html.render(content)
  }
  return make({["text/html"]: content, ["text/plain"]: content})
}

// markdown(s: string) -> Display
// Markdown, rendered like a text cell.
func nb.markdown(s){
  return make({["text/markdown"]: s, ["text/plain"]: s})
}

// svg(s: string) -> Display
// An SVG image, from its text.
func nb.svg(s){
  return make({["image/svg+xml"]: s, ["text/plain"]: "<svg image>"})
}

local func sniff(data){
  if(str.starts_with(data, "\x89PNG")){
    return "image/png"
  }
  if(str.starts_with(data, "\xff\xd8")){
    return "image/jpeg"
  }
  if(str.starts_with(data, "GIF8")){
    return "image/gif"
  }
  if(str.starts_with(data, "RIFF") and len(data) >= 12 and
    str.substring(data, 8, 12) == "WEBP"){
    return "image/webp"
  }
  if(str.contains(str.substring(data, 0, math.min(len(data), 512)), "<svg")){
    return "image/svg+xml"
  }
  return null
}

// image(data: string, mime?: string) -> Display
// An image from the bytes of its file: PNG, JPEG, GIF, WebP or SVG.
//   nb.image(os.read_file("chart.png"))
// Raises an error of kind format for bytes it does not know and no mime.
func nb.image(data, mime){
  mime = mime or sniff(data)
  if(mime == null){
    raise(error.new(error.kinds.format,
      "image: not a PNG, JPEG, GIF, WebP or SVG (pass the MIME type)"))
  }
  if(mime == "image/svg+xml"){
    return nb.svg(data)
  }
  return make({
    [mime]: encoding.base64.encode(data),
    ["text/plain"]: concat("<", mime, ", ", string(len(data)), " bytes>")
  })
}

// How [table] shows rows.
// type TableOptions = {columns?: {string}, limit?: int}
// [columns]: the keys to show, in order, for rows that are records (by
//   default the keys of the first rows, in the order they come)
// [limit]: the rows shown (200)

local func cell_text(v){
  if(v == null){
    return ""
  }
  if(type(v) == "string"){
    return v
  }
  if(type(v) == "double"){
    return str.format("%g", v)
  }
  return inspect.text(v, {width: 60, depth: 2})
}

// table(rows: {table}, options?: TableOptions) -> Display
// Rows as a table: each row a record ({name: "a", n: 1}) or a list.
func nb.table(rows, options){
  options = options or {}
  local limit = options.limit or 200
  local columns = options.columns
  local records = len(rows) > 0 and raw_type(rows[0]) == "table" and
    len(rows[0]) == 0 and count(rows[0]) > 0
  if(columns == null and records){
    columns = {}
    local seen = {}
    for(local i = 0; i < len(rows) and i < 20; i = i + 1){
      for(let local k in keys(rows[i])){
        if(not seen[k]){
          seen[k] = true
          append(columns, k)
        }
      }
    }
  }
  // the cells shown: {text, numeric} per row
  local shown = {}
  local plain = {}
  if(columns != null){
    append(plain, str.join(tbl.map(columns, string), "\t"))
  }
  local n = len(rows)
  for(local i = 0; i < n and i < limit; i = i + 1){
    local row = rows[i]
    local width = 1
    if(columns != null){
      width = len(columns)
    } else if(raw_type(row) == "table"){
      width = len(row)
    }
    local cells = {}
    local texts = {}
    for(local j = 0; j < width; j = j + 1){
      local v = row
      if(raw_type(row) == "table" and columns != null){
        v = row[columns[j]]
      } else if(raw_type(row) == "table"){
        v = row[j]
      }
      local text = cell_text(v)
      append(cells, {
        text: text, numeric: type(v) == "int" or type(v) == "double"
      })
      append(texts, text)
    }
    append(shown, cells)
    append(plain, str.join(texts, "\t"))
  }
  local more = null
  if(n > limit){
    more = concat(string(n - limit), " more rows")
    append(plain, concat("... ", more))
  }
  local markup = <>
    <table class="nb-table">
      {columns and <thead><tr>
        {tbl.map(columns, func(c){ return <th>{string(c)}</th> })}
      </tr></thead>}
      <tbody>
        {tbl.map(shown, func(cells){
          return <tr>
            {tbl.map(cells, func(c){
              return <td class={c.numeric and "num"}>{c.text}</td>
            })}
          </tr>
        })}
      </tbody>
    </table>
    {more and <div class="nb-note">{more}</div>}
  </>
  return make({
    ["text/html"]: html.render(markup), ["text/plain"]: str.join(plain, "\n")
  })
}

// ------------------------------------------------------------ plots

// One line, set of points or row of bars of a plot.
// type Series = {y: {number}, x?: {number}, label?: string, kind?: string,
//   color?: string}
// [y]: the values (a list or a buffer)
// [x]: where they are; 0, 1, 2, ... by default
// [kind]: "line", "scatter" or "bar"; the plot's by default
// [color]: a CSS colour; one of the plot's eight by default

// How [plot] draws.
// type PlotOptions = {title?: string, kind?: string, width?: int,
//   height?: int, x_label?: string, y_label?: string, y_min?: number,
//   y_max?: number}
// [kind]: "line" (the default), "scatter" or "bar"
// [width]: in pixels (640)
// [height]: in pixels (300)
// [y_min]: the lowest value of the y axis; the data's by default

local palette = {
  "#4c8dff", "#f28e2b", "#3fb68b", "#e5534b", "#a57fd8", "#d6a700", "#42b8c5",
  "#ff7ab6"
}

// a step of 1, 2 or 5 times a power of ten that gives about n ticks
local func nice_step(span, n){
  if(not (span > 0)){
    return 1.0
  }
  local raw = span / n
  local power = math.floor(math.log10(raw))
  local base = math.exp(power * math.log(10.0))
  local f = raw / base
  if(f <= 1.0){
    return base
  }
  if(f <= 2.0){
    return 2.0 * base
  }
  if(f <= 5.0){
    return 5.0 * base
  }
  return 10.0 * base
}

local func tick_text(v, step){
  if(math.abs(v) < step * 1e-9){
    v = 0.0
  }
  local a = math.abs(v)
  if(a != 0.0 and (a >= 1e6 or a < 1e-4)){
    return str.format("%.3g", v)
  }
  local decimals = 0
  if(step < 1.0){
    decimals = to_int(math.ceil(-math.log10(step) - 1e-9))
  }
  return str.format(concat("%.", string(decimals), "f"), v)
}

// a coordinate, as SVG takes it
local func num(v){
  return str.format("%.2f", v)
}

// the series of what plot was given: a list of numbers, one series, or a
// list of series
local func series_of(data){
  if(raw_type(data) == "table" and data.y != null){
    return {data}
  }
  if(raw_type(data) == "table" and len(data) > 0 and
    raw_type(data[0]) == "table" and data[0].y != null){
    return data
  }
  return {{y: data}}
}

local func x_of(s, i){
  if(s.x != null){
    return s.x[i]
  }
  return i
}

// the ranges of the series: {x0, x1, y0, y1}, NaN left out
local func ranges_of(list){
  local r = {}
  for(let local s in values(list)){
    for(local i = 0; i < len(s.y); i = i + 1){
      local y = s.y[i]
      local x = x_of(s, i)
      if(y == y and x == x){
        if(r.y0 == null or y < r.y0){ r.y0 = y }
        if(r.y1 == null or y > r.y1){ r.y1 = y }
        if(r.x0 == null or x < r.x0){ r.x0 = x }
        if(r.x1 == null or x > r.x1){ r.x1 = x }
      }
    }
  }
  if(r.y0 == null){
    return {x0: 0, x1: 1, y0: 0, y1: 1}
  }
  return r
}

// plot(data: {number} | Series | {Series}, options?: PlotOptions) -> Display
// A chart of numbers, as an SVG drawing: lines over their index, or
// series with x and y, as lines, points or bars.
//   nb.plot(samples)
//   nb.plot({{y: a, label: "dry"}, {y: b, label: "wet"}}, {title: "mix"})
//   nb.plot({x: xs, y: ys, kind: "scatter"})
// A line of more points than the plot is wide is drawn as the range of
// each column, so a second of sound plots as its envelope.
func nb.plot(data, options){
  options = options or {}
  local list = series_of(data)
  local w = options.width or 640
  local h = options.height or 300
  local left = 56
  local right = 16
  local top = 14
  local bottom = 30
  if(options.title != null){
    top = 34
  }
  if(options.x_label != null){
    bottom = 46
  }
  local labelled = false
  local bars = 0
  for(let local s in values(list)){
    if(s.label != null){
      labelled = true
    }
    if((s.kind or options.kind) == "bar"){
      bars = bars + 1
    }
  }
  if(labelled){
    right = 130
  }
  local pw = w - left - right
  local ph = h - top - bottom
  local r = ranges_of(list)
  if(bars > 0){
    r.y0 = math.min(r.y0, 0)
    r.y1 = math.max(r.y1, 0)
    r.x0 = r.x0 - 0.5
    r.x1 = r.x1 + 0.5
  }
  if(options.y_min != null){ r.y0 = options.y_min }
  if(options.y_max != null){ r.y1 = options.y_max }
  if(r.y1 == r.y0){
    r.y0 = r.y0 - 1
    r.y1 = r.y1 + 1
  }
  if(r.x1 == r.x0){
    r.x0 = r.x0 - 1
    r.x1 = r.x1 + 1
  }
  local ystep = nice_step(r.y1 - r.y0, 5)
  if(options.y_min == null){
    r.y0 = math.floor(r.y0 / ystep) * ystep
  }
  if(options.y_max == null){
    r.y1 = math.ceil(r.y1 / ystep) * ystep
  }
  local xstep = nice_step(r.x1 - r.x0, 7)
  local func px(x){
    return left + (x - r.x0) / (r.x1 - r.x0) * pw
  }
  local func py(y){
    return top + ph - (y - r.y0) / (r.y1 - r.y0) * ph
  }
  local floor_y = top + ph

  // the grid and its numbers
  local grid = {}
  local ty = math.ceil(r.y0 / ystep - 1e-9) * ystep
  for(ty <= r.y1 + ystep * 1e-6){
    local y = py(ty)
    append(grid, <>
      <line
        x1={num(left)} x2={num(left + pw)} y1={num(y)} y2={num(y)}
        stroke="currentColor" stroke-opacity="0.12"
      />
      <text
        x={num(left - 8)} y={num(y + 3.5)} text-anchor="end"
        fill="currentColor" fill-opacity="0.65"
      >{tick_text(ty, ystep)}</text>
    </>)
    ty = ty + ystep
  }
  local tx = math.ceil(r.x0 / xstep - 1e-9) * xstep
  for(tx <= r.x1 + xstep * 1e-6){
    local x = px(tx)
    append(grid, <>
      <line
        x1={num(x)} x2={num(x)} y1={num(floor_y)} y2={num(floor_y + 4)}
        stroke="currentColor" stroke-opacity="0.4"
      />
      <text
        x={num(x)} y={num(floor_y + 17)} text-anchor="middle"
        fill="currentColor" fill-opacity="0.65"
      >{tick_text(tx, xstep)}</text>
    </>)
    tx = tx + xstep
  }

  // the series
  local marks = {}
  local legend = {}
  local bar_at = 0
  for(local si = 0; si < len(list); si = si + 1){
    local s = list[si]
    local color = s.color or palette[si % len(palette)]
    local kind = s.kind or options.kind or "line"
    local n = len(s.y)
    if(kind == "bar"){
      local slot = pw / (r.x1 - r.x0)
      local bw = slot * 0.8 / bars
      for(local i = 0; i < n; i = i + 1){
        local a = py(s.y[i])
        local b = py(0)
        append(marks, <rect
          x={num(px(x_of(s, i)) - slot * 0.4 + bar_at * bw)}
          y={num(math.min(a, b))} width={num(math.max(bw - 1, 0.5))}
          height={num(math.abs(b - a))} fill={color}
        />)
      }
      bar_at = bar_at + 1
    } else if(kind == "scatter"){
      for(local i = 0; i < n; i = i + 1){
        append(marks, <circle
          cx={num(px(x_of(s, i)))} cy={num(py(s.y[i]))} r="2.5" fill={color}
          fill-opacity="0.8"
        />)
      }
    } else if(s.x == null and n > pw * 4){
      // more points than columns: the range of each column
      local path = {}
      local cols = to_int(pw)
      for(local c = 0; c < cols; c = c + 1){
        local from = to_int(c * n / cols)
        local to = to_int((c + 1) * n / cols)
        local lo = s.y[from]
        local hi = lo
        for(local i = from + 1; i < to; i = i + 1){
          local v = s.y[i]
          if(v < lo){ lo = v }
          if(v > hi){ hi = v }
        }
        local x = num(left + c + 0.5)
        local command = "L"
        if(c == 0){
          command = "M"
        }
        append(path, concat(
          command, x, " ", num(py(hi)), "L", x, " ", num(py(lo))
        ))
      }
      append(marks, <path
        d={str.join(path, "")} fill="none" stroke={color} stroke-width="1"
      />)
    } else {
      local points = {}
      for(local i = 0; i < n; i = i + 1){
        local y = s.y[i]
        if(y == y){
          append(points, concat(num(px(x_of(s, i))), ",", num(py(y))))
        }
      }
      append(marks, <polyline
        points={str.join(points, " ")} fill="none" stroke={color}
        stroke-width="1.6" stroke-linejoin="round"
      />)
    }
    if(s.label != null){
      local ly = top + 8 + si * 18
      append(legend, <>
        <rect
          x={num(left + pw + 14)} y={num(ly - 5)} width="12" height="3"
          fill={color}
        />
        <text x={num(left + pw + 32)} y={num(ly)} fill="currentColor">
          {string(s.label)}
        </text>
      </>)
    }
  }

  local drawing = <svg
    xmlns="http://www.w3.org/2000/svg" class="nb-plot"
    viewBox={concat("0 0 ", string(w), " ", string(h))} width={w} height={h}
    font-family="system-ui, sans-serif" font-size="11"
  >
    {options.title and <text
      x={num(left)} y="20" font-size="13" font-weight="600"
      fill="currentColor"
    >{options.title}</text>}
    {grid}
    <line
      x1={num(left)} x2={num(left + pw)} y1={num(floor_y)} y2={num(floor_y)}
      stroke="currentColor" stroke-opacity="0.4"
    />
    {options.x_label and <text
      x={num(left + pw / 2)} y={num(h - 8)} text-anchor="middle"
      fill="currentColor" fill-opacity="0.8"
    >{options.x_label}</text>}
    {options.y_label and <text
      transform={concat("translate(13 ", num(top + ph / 2), ") rotate(-90)")}
      text-anchor="middle" fill="currentColor" fill-opacity="0.8"
    >{options.y_label}</text>}
    {marks}
    {legend}
  </svg>
  local what = concat(string(len(list)), " series")
  if(len(list) == 1){
    what = concat(string(len(list[0].y)), " points")
  }
  return make({
    ["image/svg+xml"]: html.render(drawing),
    ["text/plain"]: concat("<plot: ", options.title or what, ">")
  })
}

// ------------------------------------------------------------ sound

local func u16(v){
  return {v & 255, (v >> 8) & 255}
}

local func u32(v){
  return {v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255}
}

// audio(samples: {number} | {{number}}, options?: {rate?: int}) -> Display
// Sound to play in the page: samples from -1 to 1 (lists or buffers), one
// channel or a list of two, at rate samples a second (44100).
//   nb.audio(voice:render(2000), {rate: 48000})
func nb.audio(samples, options){
  options = options or {}
  local rate = options.rate or 44100
  local channels = {samples}
  if(len(samples) > 0 and type(samples[0]) != "int" and
    type(samples[0]) != "double"){
    channels = samples
  }
  local ch = len(channels)
  local n = len(channels[0])
  local chunks = {}
  local bytes = {}
  for(local i = 0; i < n; i = i + 1){
    for(local c = 0; c < ch; c = c + 1){
      local v = channels[c][i]
      if(v > 1.0){
        v = 1.0
      } else if(v < -1.0){
        v = -1.0
      } else if(v != v){
        v = 0.0
      }
      local s = to_int(math.round(v * 32767.0)) & 65535
      append(bytes, s & 255)
      append(bytes, s >> 8)
    }
    if(len(bytes) >= 16384){
      append(chunks, str.from_bytes(bytes))
      bytes = {}
    }
  }
  append(chunks, str.from_bytes(bytes))
  local size = n * ch * 2
  local wav = concat(
    "RIFF", str.from_bytes(u32(36 + size)), "WAVEfmt ",
    str.from_bytes({
      16, 0, 0, 0, 1, 0, ...u16(ch), ...u32(rate), ...u32(rate * ch * 2),
      ...u16(ch * 2), 16, 0
    }),
    "data", str.from_bytes(u32(size)), str.join(chunks, "")
  )
  return make({
    ["audio/wav"]: encoding.base64.encode(wav),
    ["text/plain"]: concat(
      "<sound: ", str.format("%.2f", n / rate), " s at ", string(rate), " Hz>"
    )
  })
}

// ------------------------------------------------------------ showing

// bundle(v) -> {[string]: any}
// The forms v is shown in, by MIME type: a [Display]'s own, what
// `__display` in v's metatable gives, HTML for a slang/html node, and for
// any other value its text (notebook/inspect) and, for a table, its tree.
func nb.bundle(v){
  for(local hops = 0; hops < 8; hops = hops + 1){
    if(type(v) == "notebook.Display"){
      return v.data
    }
    if(raw_type(v) != "table"){
      break
    }
    local m = v.@meta
    if(m == null or raw_type(m) != "table" or
      get_raw(m, "__display") == null){
      break
    }
    v = get_raw(m, "__display")(v)
  }
  if(html.is_node(v)){
    local s = html.render(v)
    return {["text/html"]: s, ["text/plain"]: s}
  }
  local data = {["text/plain"]: inspect.text(v)}
  if(raw_type(v) == "table"){
    data[VALUE] = inspect.tree(v)
  }
  return data
}

// display(...values)
// Shows each value now, as a cell's last value would be shown: under the
// cell in a notebook, as text on a terminal.
func nb.display(...values){
  local n = tbl.span(values)
  for(local i = 0; i < n; i = i + 1){
    local data = nb.bundle(values[i])
    if(sink != null){
      sink("display", data)
    } else {
      print(data["text/plain"], "\n")
    }
  }
}

// clear()
// Takes away what the running cell has shown so far, for output that
// replaces itself: progress, a picture that changes.
func nb.clear(){
  if(sink != null){
    sink("clear", null)
  }
}

return nb
