// Ripples on a pond: a fragment shader over the whole window, written as
// WGSL in a `wgsl` block (the extension gpu/syntax), with a uniform block
// for the time, the window's size and the mouse. Move the mouse to move
// the fourth source, click to change the colors, escape to quit.
//   cd examples/gpu && ../../bin/slang run waves.slang
extension "gpu/syntax"
local gpu = require("gpu")
local window = require("window")
local buffer = require("slang/buffer")
local os = require("slang/os")
local str = require("slang/string")
local time = require("slang/time")

wgsl pond {
  struct Uniforms {
    size: vec2f, // the window, in pixels
    mouse: vec2f, // the cursor, in pixels
    time: f32, // seconds
    palette: f32,
  }
  @group(0) @binding(0) var<uniform> u: Uniforms;

  // one triangle that covers the window
  @vertex
  fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    var corners = array(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    return vec4f(corners[i], 0.0, 1.0);
  }

  // the height of the wave a source makes at p
  fn ripple(p: vec2f, source: vec2f, speed: f32) -> f32 {
    let d = distance(p, source);
    return sin(d * 42.0 - u.time * speed) / (1.0 + d * 6.0);
  }

  fn palette(t: f32) -> vec3f {
    let phase = vec3f(0.0, 0.33, 0.67) + u.palette * 0.21;
    return 0.5 + 0.5 * cos(6.2831853 * (t + phase));
  }

  @fragment
  fn fs(@builtin(position) at: vec4f) -> @location(0) vec4f {
    // window coordinates with the short side from -1 to 1
    let scale = 2.0 / min(u.size.x, u.size.y);
    let p = (at.xy - 0.5 * u.size) * scale;
    let mouse = (u.mouse - 0.5 * u.size) * scale;

    var height = ripple(p, mouse, 5.0);
    for (var k = 0; k < 3; k++) {
      let angle = f32(k) * 2.0944 + u.time * 0.15;
      height += ripple(p, 0.6 * vec2f(cos(angle), sin(angle)), 4.0);
    }
    let shade = 0.55 + 0.45 * height;
    return vec4f(palette(height * 0.35 + 0.1) * shade, 1.0);
  }
}

local win = window.open({
  title: "waves", width: 800, height: 600, resizable: true
})
local device = gpu.device()
local surface = device:surface(win)
local pipeline = device:render_pipeline({
  shader: device:shader(pond),
  fragment: {targets: {{format: surface.format}}},
})

// Uniforms, as WGSL lays the struct out: six floats
local values_of = buffer.new("float", 6)
local uniforms = device:buffer({
  size: values_of.size,
  usage: "uniform|copy_dst",
})
local bind_group = device:bind_group({
  layout: pipeline:bind_group_layout(0),
  entries: {{binding: 0, resource: uniforms}},
})

local started = time.clock()
local mouse = {400, 300}
local palette = 0
local frames = 0
// WAVES_FRAMES=n stops after n frames (for tests)
local limit = os.getenv("WAVES_FRAMES")
for(win.open){
  for(let local e in values(win:events())){
    if(e.type == "key_down" and e.key == "escape"){
      win:close()
    } else if(e.type == "mouse_move"){
      mouse = {e.x, e.y}
    } else if(e.type == "mouse_down"){
      palette = palette + 1
    }
  }
  if(not win.open){
    break
  }
  local frame = surface:texture()
  if(frame != null){
    // (the mouse is in the window's points, the surface in pixels)
    local density = surface.width / win.width
    values_of[0] = surface.width
    values_of[1] = surface.height
    values_of[2] = mouse[0] * density
    values_of[3] = mouse[1] * density
    values_of[4] = (time.clock() - started) / 1000
    values_of[5] = palette
    uniforms:write(values_of)

    local encoder = device:encoder()
    local pass = encoder:render_pass({
      color_attachments: {{view: frame:view(), clear_value: {0, 0, 0, 1}}},
    })
    pass:set_pipeline(pipeline)
    pass:set_bind_group(0, bind_group)
    pass:draw(3)
    pass:finish()
    device.queue:submit(encoder:finish())
    surface:present()
  }
  frames = frames + 1
  if(limit != null and frames >= str.to_number(limit)){
    win:close()
  }
}
