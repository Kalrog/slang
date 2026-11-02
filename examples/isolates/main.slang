// Renders the Mandelbrot set into a shared buffer with a pool of isolates,
// once with one worker and once with one per CPU, and writes the image as
// mandelbrot.pgm. Workers take rows from a channel and write their pixels
// straight into the shared buffer; only row numbers and counts are copied.
//
//   bin/slang run examples/isolates/main.slang [width] [height]

local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local os = require("slang/os")
local time = require("slang/time")
local str = require("slang/string")

local argv = args()
local width = if(len(argv) > 0){ to_int(argv[0]) } else { 800 }
local height = if(len(argv) > 1){ to_int(argv[1]) } else { 600 }

// one worker: renders the rows it receives until the channel closes and
// returns how many it did (it uses only its arguments: it crosses as
// bytecode)
local func render_rows(rows, pixels, width, height){
  local done = 0
  for(let local y in require("slang/isolate").each(rows)){
    local ci = (y / height) * 2.4 - 1.2
    local base = y * width
    for(local x = 0; x < width; x = x + 1){
      local cr = (x / width) * 3.5 - 2.5
      local zr = 0.0
      local zi = 0.0
      local n = 0
      for(n < 255 and zr * zr + zi * zi < 4.0){
        local t = zr * zr - zi * zi + cr
        zi = 2.0 * zr * zi + ci
        zr = t
        n = n + 1
      }
      pixels[base + x] = 255 - n
    }
    done = done + 1
  }
  return done
}

local func render(workers){
  local pixels = buffer.shared("uint8_t", width * height)
  local rows = isolate.channel()
  local pool = {}
  for(local i = 0; i < workers; i = i + 1){
    append(pool, isolate.spawn(render_rows, rows, pixels, width, height))
  }
  for(local y = 0; y < height; y = y + 1){
    rows:send(y)
  }
  rows:close()
  local total = 0
  for(let local w in values(pool)){
    total = total + w:join()
  }
  assert(total == height, "every row once")
  return pixels
}

local func timed(workers){
  local t0 = time.clock()
  local pixels = render(workers)
  local ms = time.clock() - t0
  print(str.format("%2d worker(s): %7.1f ms\n", workers, ms))
  return {pixels: pixels, ms: ms}
}

local one = timed(1)
local cpus = os.cpu_count()
local many = timed(cpus)
print(str.format("speedup with %d isolates: %.1fx\n", cpus, one.ms / many.ms))
assert(one.pixels == many.pixels, "both renders agree")

local header = str.format("P5\n%d %d\n255\n", width, height)
os.write_file("mandelbrot.pgm", concat(header, many.pixels:to_string()))
print("wrote mandelbrot.pgm\n")
