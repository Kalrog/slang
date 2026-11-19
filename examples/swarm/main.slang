// swarm: a million particles simulated on the GPU, with sound that follows
// them. A compute shader moves them through a flow field toward or away
// from the cursor; they are drawn straight from the same storage buffer as
// additive dots into an HDR target, then tone-mapped onto the window. The
// GPU also adds up their energy, read back a few times a second, which
// steers the sound computed in slang (sim/sound).
//
// Raylib could not do this: its OpenGL 3.3 has no compute shaders or
// storage buffers on macOS, so the particles would have to live in slang
// and be uploaded every frame. It also has no gamepad rumble.
//
//   cd examples/swarm && ../../bin/slang run main.slang
//
// Mouse: left button pulls, right button pushes, space or middle button
// sends a shock wave, wheel changes the flow. 1-3 change colors, F toggles
// fullscreen, R scatters the swarm again, Escape quits. A gamepad works
// too: left stick moves the cursor, right trigger pulls, left trigger
// pushes, south button for the shock wave (it rumbles).
//
// SWARM_COUNT sets the number of particles (1048576 by default);
// SWARM_FRAMES=n quits after n frames (for tests).
local gpu = require("gpu")
local window = require("window")
local buffer = require("slang/buffer")
local math = require("slang/math")
local os = require("slang/os")
local str = require("slang/string")
local time = require("slang/time")
local swarm = require("sim/shaders")
local sound = require("sim/sound")

local count = str.to_number(os.getenv("SWARM_COUNT") or "1048576") | 0
local frame_limit = str.to_number(os.getenv("SWARM_FRAMES") or "0") | 0

local win = window.open({
  title: "swarm", width: 1280, height: 800, resizable: true
})
local device = gpu.device()
local surface = device:surface(win)

// ---- buffers: of the program's structs
local particles = device:buffer({
  type: swarm.Particle, count: count, usage: "storage"
})
local energy = device:buffer({size: 4, usage: "storage|copy_src|copy_dst"})
local u = swarm.Uniforms:new({exposure: 1.4, size: 0.004})
local uniforms = device:buffer({
  type: swarm.Uniforms,
  usage: "uniform|copy_dst",
})

// ---- pipelines: one for each entry point
local seed_pipeline = device:compute_pipeline(swarm.seed)
local step_pipeline = device:compute_pipeline(swarm.step)
local draw_pipeline = device:render_pipeline({
  vertex: {module: swarm.draw_vs},
  fragment: {
    module: swarm.draw_fs,
    targets: {{format: "rgba16_float", blend: "additive"}},
  },
  primitive: {topology: "triangle_strip"},
})
local tonemap_pipeline = device:render_pipeline({
  vertex: {module: swarm.tone_vs},
  fragment: {module: swarm.tone_fs, targets: {{format: surface.format}}},
})

// the program's variables by name; a pipeline binds the ones it uses
local resources = {
  u: uniforms, particles: particles, shown: particles, energy: energy
}
local seed_group = seed_pipeline:bind(resources)
local step_group = step_pipeline:bind(resources)
local draw_group = draw_pipeline:bind(resources)

// the HDR target and its tone-mapping bind group, made again when the
// window's size changes
local hdr = null
local hdr_view = null
local tonemap_group = null
local func hdr_for(w, h){
  if(hdr == null or hdr.width != w or hdr.height != h){
    hdr = device:texture({
      size: {w, h},
      format: "rgba16_float",
      usage: "render_attachment|texture_binding",
    })
    hdr_view = hdr:view()
    tonemap_group = tonemap_pipeline:bind({hdr: hdr_view, u: uniforms})
  }
  return hdr_view
}

// one invocation for each particle
local func dispatch(pipeline, group){
  local encoder = device:encoder()
  local pass = encoder:compute_pass()
  pass:set_pipeline(pipeline)
  pass:set_bind_group(0, group)
  pass:dispatch(count)
  pass:finish()
  return encoder
}

// ---- state
local mouse = {0.0, 0.0}
local force = 0.0
local flow = 0.6
local palette = 0
local burst = 0.0
local start = time.clock()
local last = start
local audio = sound.start()
local zero = buffer.new("uint32_t", 1)
local pad = null

local func scatter(){
  u.time = (time.clock() - start) / 1000
  uniforms:write(u)
  device.queue:submit(dispatch(seed_pipeline, seed_group):finish())
}

local func shock(){
  burst = 6.0
  audio.whoosh:play({volume: 0.8, pitch: 0.9 + math.random() * 0.3})
  if(pad != null){
    pad:rumble(0.4, 0.8, 180)
  }
}

// window points to world units: y from -1 (bottom) to 1, x scaled by aspect
local func to_world(x, y){
  local aspect = win.width / win.height
  return {(x / win.width * 2 - 1) * aspect, 1 - y / win.height * 2}
}

u.aspect = win.width / win.height
scatter()

local frames = 0
local fps_frames = 0
local fps_since = start
for(win.open){
  for(let local e in values(win:events())){
    local t = e.type
    if(t == "key_down"){
      if(e.key == "escape"){
        win:close()
      } else if(e.key == "space" and not e.repeat){
        shock()
      } else if(e.key == "f"){
        win.fullscreen = not win.fullscreen
      } else if(e.key == "r"){
        scatter()
      } else if(e.key == "1" or e.key == "2" or e.key == "3"){
        palette = str.to_number(e.key) - 1
      }
    } else if(t == "mouse_move"){
      mouse = to_world(e.x, e.y)
    } else if(t == "mouse_down"){
      if(e.button == "left"){
        force = 1.0
      } else if(e.button == "right"){
        force = -1.0
      } else {
        shock()
      }
    } else if(t == "mouse_up" and (e.button == "left" or e.button == "right")){
      force = 0.0
    } else if(t == "wheel"){
      flow = math.clamp(flow + e.dy * 0.05, 0.0, 3.0)
    } else if(t == "gamepad_added"){
      pad = e.gamepad
    } else if(t == "gamepad_removed" and e.gamepad == pad){
      pad = null
    } else if(t == "gamepad_down" and e.button == "south"){
      shock()
    }
  }
  if(not win.open){
    break
  }

  local now = time.clock()
  local dt = math.min((now - last) / 1000, 1 / 30)
  last = now

  if(pad != null){
    local x = pad:axis("leftx")
    local y = pad:axis("lefty")
    if(math.abs(x) > 0.15 or math.abs(y) > 0.15){
      local aspect = win.width / win.height
      mouse = {
        math.clamp(mouse[0] + x * dt * 1.5, -aspect, aspect),
        math.clamp(mouse[1] - y * dt * 1.5, -1, 1),
      }
    }
    local pull = pad:axis("right_trigger") - pad:axis("left_trigger")
    if(math.abs(pull) > 0.1){
      force = pull
    }
  }

  local frame = surface:texture()
  if(frame != null){
    u.mouse = mouse
    u.aspect = surface.width / surface.height
    u.time = (now - start) / 1000
    u.dt = dt
    u.force = force
    u.burst = burst
    u.flow = flow
    u.palette = palette
    uniforms:write(u)
    burst = 0.0

    local encoder = dispatch(step_pipeline, step_group)
    local draw = encoder:render_pass({
      color_attachments: {
        {
          view: hdr_for(surface.width, surface.height),
          clear_value: {0, 0, 0, 1},
        },
      },
    })
    draw:set_pipeline(draw_pipeline)
    draw:set_bind_group(0, draw_group)
    draw:draw(4, count)
    draw:finish()
    local show = encoder:render_pass({
      color_attachments: {
        {view: frame:view(), clear_value: {0, 0, 0, 1}},
      },
    })
    show:set_pipeline(tonemap_pipeline)
    show:set_bind_group(0, tonemap_group)
    show:draw(3)
    show:finish()
    device.queue:submit(encoder:finish())
    surface:present()

    // every 8th frame: the mean squared speed of the sampled particles,
    // added up by the GPU over those 8 frames
    // (read without waiting for the GPU: the answer comes with a later
    // frame's present, and the sum starts again at once)
    if(frames % 8 == 7){
      energy:read_async("uint32_t"):then(func(sums){
        local mean = sums[0] / 1000.0 / (count / 64.0) / 8
        audio.params[sound.ENERGY] = math.sqrt(mean)
      })
      energy:write(zero)
    }
    audio.params[sound.FORCE] = force
    audio.params[sound.PAN] = mouse[0] / u.aspect
  }

  frames = frames + 1
  fps_frames = fps_frames + 1
  if(now - fps_since >= 1000){
    win.title = concat(
      "swarm: ", count, " particles, ",
      math.round(fps_frames * 1000 / (now - fps_since)), " fps"
    )
    fps_frames = 0
    fps_since = now
  }
  if(frame_limit > 0 and frames >= frame_limit){
    win:close()
  }
}

local stats = audio.player:stats()
audio.player:stop()
if(frame_limit > 0){
  print(
    frames, " frames, ", math.round(frames * 1000 / (time.clock() - start)),
    " fps, energy ", audio.params[sound.ENERGY], ", sound load ", stats.load,
    ", underruns ", stats.underruns, "\n"
  )
}
