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
// unfold, and a [Display] as what it is: HTML, an image, a plot, sound, code.
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
local hash = require("slang/hash")
local html = require("slang/html")
local tbl = require("slang/table")
local inspect = require("notebook/inspect")

local nb = {}

// Something to show, in one or more forms: the page takes the richest it
// knows, a terminal the text. Made by [html], [markdown], [code], [svg],
// [image], [pixels], [table], [plot], [audio] and [text].
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

// where displays go while a kernel runs the code: sink(kind, data, cell?)
local sink = null
// the cell whose code runs, as the kernel names it
local where = func(){ return null }

// attach(f?: func(kind: string, data: table?, cell?: string),
//   current?: func(): string)
// Sends what [display], [clear] and an [Output] show to f from now on
// (null: back to printing): kind is "display" with a [Display]'s data,
// "update" with an output's new data and the cell that has it, or
// "clear". current names the cell whose code runs: the one that has the
// controls and outputs made now. The notebook's kernel calls it; a
// program has no reason to.
func nb.attach(f, current){
  sink = f
  where = current or func(){ return null }
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

// code(source: string, language?: string) -> Display
// Source code shown as code: a program a cell made, a file it read. In a
// notebook slang is coloured as the cells are.
//   nb.code(spec:source())
//   nb.code(os.read_file("rules.lisp"), "lisp")
// [language]: "slang" by default
func nb.code(source, language){
  source = str.trim_end(source, "\n")
  // a fence longer than any run of backticks in the code
  local longest = 2
  local run = 0
  for(local i = 0; i < len(source); i = i + 1){
    if(str.byte_at(source, i) == '`'){
      run = run + 1
      if(run > longest){
        longest = run
      }
    } else {
      run = 0
    }
  }
  local fence = "`" * (longest + 1)
  return make({
    ["text/markdown"]: concat(
      fence, language or "slang", "\n", source, "\n", fence
    ),
    ["text/plain"]: source
  })
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

// four bytes of an int, the high one first
local func be32(v){
  return str.from_bytes({(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255})
}

// a part of a PNG file: its length, its name, its data and their checksum
local func png_chunk(name, data){
  local body = concat(name, data)
  return concat(be32(len(data)), body, be32(hash.crc32(body)))
}

// data as a zlib stream without compression (stored blocks), for where
// slang has no zlib: in a browser
local func zlib_stored(data, adler){
  local parts = {"\x78\x01"}
  local n = len(data)
  local at = 0
  for(true){
    local size = math.min(n - at, 65535)
    local last = at + size >= n
    // (a block says its length twice, the second time inverted)
    local inverse = ~size & 65535
    append(parts, str.from_bytes({
      last and 1 or 0, size & 255, size >> 8, inverse & 255, inverse >> 8
    }))
    append(parts, str.substring(data, at, at + size))
    at = at + size
    if(last){
      break
    }
  }
  append(parts, be32(adler))
  return str.join(parts, "")
}

// a colour's part as a byte: 0 to 1, clamped
local func level(v){
  if(type(v) != "double" and type(v) != "int"){
    return 0
  }
  if(v >= 1){
    return 255
  }
  if(v > 0){
    return to_int(v * 255 + 0.5)
  }
  // (0, below it, and what is no number at all)
  return 0
}

// How [pixels] makes its image.
// type PixelOptions = {compress?: bool}
// [compress]: false keeps the pixels as they are in the file (larger).
//   That is also what happens where slang has no zlib: in a browser

// pixels(width: int, height: int, color: func(x: int, y: int): any,
//   options?: PixelOptions) -> Display
// An image made a pixel at a time (a PNG): color gives the pixel in column
// x (0 at the left) of row y (0 at the top), as a grey from 0 (black) to 1
// (white), or as {red, green, blue}, each from 0 to 1.
//   nb.pixels(256, 256, func(x, y){ return {x / 255, y / 255, 0.5} })
// Raises an error of kind argument for a size that is no image's.
func nb.pixels(width, height, color, options){
  if(type(width) != "int" or type(height) != "int" or width < 1 or
    height < 1 or width * height > 16 * 1024 * 1024){
    raise(error.new(error.kinds.argument,
      "pixels: a width and a height from 1 on, and no more than 16 million pixels"))
  }
  local rows = {}
  // (the checksum of the pixels' bytes, Adler-32, made as they are)
  local a = 1
  local b = 0
  for(local y = 0; y < height; y = y + 1){
    // a row starts with how it is filtered: not
    local bytes = {0}
    b = (b + a) % 65521
    for(local x = 0; x < width; x = x + 1){
      local c = color(x, y)
      local red = 0
      local green = 0
      local blue = 0
      if(raw_type(c) == "table"){
        red = level(c[0])
        green = level(c[1])
        blue = level(c[2])
      } else {
        red = level(c)
        green = red
        blue = red
      }
      append(bytes, red)
      append(bytes, green)
      append(bytes, blue)
      a = a + red
      b = b + a
      a = a + green
      b = b + a
      a = (a + blue) % 65521
      b = (b + a) % 65521
    }
    append(rows, str.from_bytes(bytes))
  }
  local raw = str.join(rows, "")
  local packed = null
  if(options == null or options.compress != false){
    local zlib = try { require("slang/zlib") } catch { null }
    if(zlib != null){
      packed = zlib.deflate(raw, {format: "zlib"})
    }
  }
  if(packed == null){
    packed = zlib_stored(raw, (b << 16) | a)
  }
  local png = concat(
    "\x89PNG\r\n\x1a\n",
    // 8 bits a part, red green blue
    png_chunk("IHDR", concat(be32(width), be32(height), "\x08\x02\x00\x00\x00")),
    png_chunk("IDAT", packed), png_chunk("IEND", ""),
  )
  return make({
    ["image/png"]: encoding.base64.encode(png),
    ["text/plain"]: concat("<image, ", string(width), " x ", string(height), ">")
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

// ------------------------------------------------------------ controls

// the mime types of a control and of an output that can be replaced
local CONTROL = "application/vnd.slang.control+json"
local OUTPUT = "application/vnd.slang.output"

// what makes this kernel's controls and outputs its own: a control from
// an earlier kernel is one the page can tell is no longer live
local instance = concat("k", string(to_int(math.random() * 2147483647)))
local made = 0
local func new_name(){
  made = made + 1
  return concat(instance, "-", string(made))
}

// instance() -> string
// What the names of this kernel's controls start with (and a "-"). The
// notebook's kernel tells the page, which greys out the others.
func nb.instance(){
  return instance
}

// the controls and the handlers there are, by name: {control?, handler?,
// cell}
local registry = {}

// A control in a notebook's page, from [slider], [checkbox], [dropdown],
// [input] and [button]: shown like any other value, and what the page
// does with it calls on_change in the kernel, with the cells' locals.
// type Control = {name: string, kind: string, value: any, label?: string,
//   on_change?: func(value: any): any}
// [name]: what the page calls it by
// [kind]: "slider", "checkbox", "dropdown", "input" or "button"
// [value]: what it is set to now; it follows the page
// [on_change]: called with the new value when the page changes it (a
//   button's is null); may be set later
local control_meta = {__type: "notebook.Control"}

local func control_spec(c){
  local spec = {name: c.name, kind: c.kind, label: c.label, value: c.value}
  if(c.kind == "slider"){
    spec.min = c.min
    spec.max = c.max
    spec.step = c.step
    spec.scale = c.scale
  } else if(c.kind == "dropdown"){
    spec.options = tbl.map(c.options, func(o){ return string(o) })
    spec.value = tbl.index_of(c.options, c.value)
  } else if(c.kind == "input"){
    spec.placeholder = c.placeholder
  } else if(c.kind == "panel"){
    spec.controls = tbl.map(c.controls, control_spec)
  }
  return spec
}

// a control as a page that cannot run it shows it, from its spec (what
// the page gets): as it was last set
local func Still(props){
  local c = props.spec
  local label = c.label and <span class="nb-control-label">{string(c.label)}</span>
  if(c.kind == "slider" and c.scale == "log"){
    // (where the value is between min and max, in thousandths of the way)
    local at = to_int(1000 * math.log(c.value / c.min) / math.log(c.max / c.min))
    return <label class="nb-control nb-slider">{label}
      <input type="range" min="0" max="1000" step="1" value={string(at)} disabled/>
      <output>{string(c.value)}</output>
    </label>
  }
  if(c.kind == "slider"){
    return <label class="nb-control nb-slider">{label}
      <input type="range" min={string(c.min)} max={string(c.max)}
        step={string(c.step)} value={string(c.value)} disabled/>
      <output>{string(c.value)}</output>
    </label>
  }
  if(c.kind == "checkbox"){
    return <label class="nb-control nb-checkbox">
      {c.value == true and <input type="checkbox" checked disabled/> or
        <input type="checkbox" disabled/>}
      {label}
    </label>
  }
  if(c.kind == "dropdown"){
    local options = c.options or {}
    local shown = {}
    for(local i = 0; i < len(options); i = i + 1){
      append(shown, i == c.value and <option selected>{string(options[i])}</option> or
        <option>{string(options[i])}</option>)
    }
    return <label class="nb-control nb-dropdown">{label}
      <select disabled>{shown}</select>
    </label>
  }
  if(c.kind == "input"){
    return <label class="nb-control nb-input">{label}
      <input type="text" value={string(c.value or "")} disabled/>
    </label>
  }
  if(c.kind == "button"){
    return <span class="nb-control nb-button">
      <button disabled>{string(c.label or "Run")}</button>
    </span>
  }
  return <div class="nb-panel">
    {tbl.map(c.controls or {}, func(k){ return <Still spec={k}/> })}
  </div>
}

// control_html(spec: table) -> string
// A control as HTML that does nothing: what an exported page shows of
// it, from the spec its data carries (application/vnd.slang.control+json).
func nb.control_html(spec){
  return html.render(<Still spec={spec}/>)
}

local func control_text(c){
  if(c.kind == "panel"){
    return str.join(tbl.map(c.controls, control_text), "  ")
  }
  if(c.kind == "button"){
    return concat("[", c.label or "Run", "]")
  }
  return concat(c.label or c.kind, ": ", inspect.text(c.value))
}

control_meta.__display = func(c){
  return make({
    [CONTROL]: control_spec(c),
    ["text/html"]: nb.control_html(control_spec(c)),
    ["text/plain"]: control_text(c)
  })
}

local func new_control(kind, options, on_change){
  local c = {
    kind: kind, name: new_name(), label: options.label, value: options.value,
    on_change: on_change
  }
  c.@meta = control_meta
  registry[c.name] = {control: c, cell: where()}
  return c
}

local func number_or(v, default){
  if(type(v) == "int" or type(v) == "double"){
    return v
  }
  return default
}

// How [slider] and the other controls start.
// type ControlOptions = {label?: string, value?: any, min?: number,
//   max?: number, step?: number, scale?: string, options?: {any},
//   placeholder?: string}
// [label]: the text beside it
// [value]: what it is set to at first
// [min], [max], [step]: a slider's range (0 to 1) and its step (1 for a
//   range of ints, else the power of ten nearest below a hundredth of
//   the range)
// [scale]: "log" for a slider whose equal moves multiply its value by as
//   much (a frequency, a time): min must be above 0; the value is not
//   rounded to a step unless step is given
// [options]: a dropdown's choices: any values, shown as their text
// [placeholder]: what an empty input shows

// slider(options?: ControlOptions, on_change?: func(value: number)) -> Control
// A number from min to max.
//   local speed = nb.slider({label: "speed", min: 1, max: 10}, func(v){
//     print("now ", v, "\n")
//   })
func nb.slider(options, on_change){
  options = options or {}
  local lo = number_or(options.min, 0)
  local hi = number_or(options.max, 1)
  if(hi < lo){
    raise(error.new(error.kinds.argument, "slider: max is below min"))
  }
  local step = options.step
  local log = options.scale == "log"
  if(log and not (lo > 0 and hi > lo)){
    raise(error.new(error.kinds.argument,
      "slider: a log scale needs 0 < min < max"))
  }
  if(log){
    // (the page moves it smoothly; its value is not rounded)
  } else if(step == null){
    if(type(lo) == "int" and type(hi) == "int"){
      step = 1
    } else if(hi > lo){
      // a power of ten, about a hundredth of the range
      local target = (hi - lo) / 100
      step = 1.0
      for(step > target){
        step = step / 10
      }
      for(step * 10 <= target){
        step = step * 10
      }
    } else {
      step = 0.01
    }
  }
  local c = new_control("slider", options, on_change)
  c.min = lo
  c.max = hi
  c.step = step
  if(log){
    c.scale = "log"
  }
  c.value = number_or(options.value, lo)
  return c
}

// checkbox(options?: ControlOptions, on_change?: func(value: bool)) -> Control
// Yes or no; false at first unless options.value says otherwise.
func nb.checkbox(options, on_change){
  options = options or {}
  local c = new_control("checkbox", options, on_change)
  c.value = options.value == true
  return c
}

// dropdown(options: ControlOptions, on_change?: func(value: any)) -> Control
// One of options.options; the first unless options.value is another.
//   nb.dropdown({label: "wave", options: {"sine", "saw"}}, func(w){ ... })
// Raises an error of kind argument without options to choose from.
func nb.dropdown(options, on_change){
  if(options == null or raw_type(options.options) != "table" or
    len(options.options) == 0){
    raise(error.new(error.kinds.argument, "dropdown: options to choose from"))
  }
  local c = new_control("dropdown", options, on_change)
  c.options = options.options
  if(tbl.index_of(c.options, c.value) < 0){
    c.value = c.options[0]
  }
  return c
}

// input(options?: ControlOptions, on_change?: func(value: string)) -> Control
// A line of text: on_change gets it when enter is pressed or it is left.
func nb.input(options, on_change){
  options = options or {}
  local c = new_control("input", options, on_change)
  c.value = string(options.value or "")
  c.placeholder = options.placeholder
  return c
}

// button(label: string | ControlOptions, on_click?: func()) -> Control
// A button: on_click is called with each click.
//   nb.button("Roll", func(){ dice:show(math.random(1, 6)) })
func nb.button(label, on_click){
  local options = label
  if(raw_type(label) != "table"){
    options = {label: label}
  }
  return new_control("button", options, on_click)
}

// panel(controls: {Control} | {[string]: Control}) -> Display
// The controls side by side, in one box: a list, or a record whose keys
// label the controls that have no label of their own.
func nb.panel(controls){
  local list = {}
  for(let local e in entries(controls)){
    local c = e[1]
    if(type(c) != "notebook.Control"){
      raise(error.new(error.kinds.argument, "panel: controls only"))
    }
    if(c.label == null and type(e[0]) == "string"){
      c.label = e[0]
    }
    append(list, c)
  }
  local p = {kind: "panel", controls: list}
  return make({
    [CONTROL]: control_spec(p),
    ["text/html"]: nb.control_html(control_spec(p)),
    ["text/plain"]: control_text(p)
  })
}

// on(name: string, f: func(value: any): any)
// What the page's own HTML can call: `slang.call(name, value)` in a
// script of a cell's HTML calls f with value (what JSON carries) and is
// a promise of what f gives back (as JSON; null for what JSON has no
// form of).
//   nb.on("roll", func(sides){ return math.random(1, sides) })
//   nb.html("<button onclick='slang.call(\"roll\", 6).then(alert)'>roll</button>")
func nb.on(name, f){
  if(type(name) != "string" or str.starts_with(name, concat(instance, "-"))){
    raise(error.new(error.kinds.argument, "on: a name of your own"))
  }
  registry[name] = {handler: f, cell: where()}
}

// ------------------------------------------------------------ outputs

// What [output] gives: a place under the cell whose content is replaced.
// type Output = {name: string, show: func(...values), clear: func()}
// [show]: shows the values there instead of what it showed (one value, or
//   several, one under another)
// [clear]: shows nothing there
local output_methods = {}
local output_meta = {__index: output_methods, __type: "notebook.Output"}

local func output_data(name, values){
  local n = tbl.span(values)
  local data = null
  if(n == 1){
    data = nb.bundle(values[0])
  } else {
    // several: one under another
    local parts = {}
    local texts = {}
    for(local i = 0; i < n; i = i + 1){
      local d = nb.bundle(values[i])
      append(parts, d)
      append(texts, d["text/plain"] or "")
    }
    data = {["text/plain"]: str.join(texts, "\n")}
    data["application/vnd.slang.stack+json"] = parts
  }
  local out = {}
  for(let local e in entries(data)){
    out[e[0]] = e[1]
  }
  out[OUTPUT] = name
  return out
}

// output(...values) -> Output
// Shows the values now (or nothing), at a place whose content [Output.show]
// replaces later: from a cell, or from a control's on_change.
//   local view = nb.output()
//   nb.slider({max: 10}, func(v){ view:show(nb.plot(curve(v))) })
func nb.output(...values){
  local o = {name: new_name(), cell: where()}
  o.@meta = output_meta
  local data = output_data(o.name, values)
  if(sink != null){
    sink("display", data)
  } else if(tbl.span(values) > 0){
    print(data["text/plain"], "\n")
  }
  return o
}

func output_methods.show(o, ...values){
  local data = output_data(o.name, values)
  if(sink != null){
    sink("update", data, o.cell)
  } else {
    print(data["text/plain"], "\n")
  }
}

func output_methods.clear(o){
  output_methods.show(o)
}

// interact(controls: {[string]: Control}, f: func(values: table): any)
// Controls, and under them what f gives for what they are set to, again
// each time one changes: f gets a record of their values by the same
// keys. A control's own on_change is called first.
//   nb.interact({t: nb.slider({max: 6.0})}, func(v){ return draw(v.t) })
func nb.interact(controls, f){
  local func current(){
    local v = {}
    for(let local e in entries(controls)){
      v[e[0]] = e[1].value
    }
    return v
  }
  local panel = nb.panel(controls)
  nb.display(panel)
  local view = nb.output(f(current()))
  for(let local e in entries(controls)){
    local c = e[1]
    local own = c.on_change
    c.on_change = func(value){
      if(own != null){
        own(value)
      }
      view:show(f(current()))
    }
  }
  return null
}

// owner(name: string) -> string?
// The cell that made the control or handler named so, or null when there
// is none (it is from an earlier kernel, or its cell ran again).
func nb.owner(name){
  local r = registry[name]
  return r and r.cell
}

// forget(cell: string)
// The controls and handlers the cell made are no longer called: it runs
// again. The notebook's kernel calls it.
func nb.forget(cell){
  for(let local e in values(tbl.entries(registry))){
    if(e[1].cell == cell){
      delete(registry, e[0])
    }
  }
}

// a value from the page as the control takes it
local func coerce(c, value){
  if(c.kind == "slider"){
    local v = number_or(value, c.value)
    if(c.scale != "log" and type(c.step) == "int" and type(c.min) == "int"){
      v = to_int(math.floor(v + 0.5))
    }
    return math.max(c.min, math.min(c.max, v))
  }
  if(c.kind == "checkbox"){
    return value == true
  }
  if(c.kind == "dropdown"){
    if(type(value) == "int" and value >= 0 and value < len(c.options)){
      return c.options[value]
    }
    return c.value
  }
  if(c.kind == "input"){
    return string(value or "")
  }
  return null
}

// call(name: string, value: any) -> any
// What the page asks for: the control named so takes the value and its
// on_change is called with it, or the handler is called with it; gives
// what that gives. Raises an error of kind not_found for a name there is
// nothing by. The notebook's kernel calls it.
func nb.call(name, value){
  local r = registry[name]
  if(r == null){
    raise(error.new(error.kinds.not_found,
      "this control is from an earlier run: run its cell again"))
  }
  if(r.handler != null){
    return r.handler(value)
  }
  local c = r.control
  if(c.kind != "button"){
    c.value = coerce(c, value)
  }
  if(c.on_change == null){
    return null
  }
  if(c.kind == "button"){
    return c.on_change()
  }
  return c.on_change(c.value)
}

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
