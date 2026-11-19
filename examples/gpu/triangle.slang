// A colored triangle in a window: the smallest program drawing with the
// gpu and window packages. Escape closes it.
//   cd examples/gpu && ../../bin/slang run triangle.slang
extension "gpu/syntax"
local gpu = require("gpu")
local window = require("window")
local os = require("slang/os")
local str = require("slang/string")

// the shader: WGSL, in the file that uses it
wgsl colors {
  struct Out {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
  }

  @vertex
  fn vs(@builtin(vertex_index) i: u32) -> Out {
    var points = array(vec2f(0.0, 0.6), vec2f(-0.6, -0.5), vec2f(0.6, -0.5));
    var colors = array(
      vec3f(1.0, 0.3, 0.2),
      vec3f(0.2, 0.9, 0.4),
      vec3f(0.2, 0.4, 1.0),
    );
    var out: Out;
    out.position = vec4f(points[i], 0.0, 1.0);
    out.color = colors[i];
    return out;
  }

  @fragment
  fn fs(in: Out) -> @location(0) vec4f {
    return vec4f(in.color, 1.0);
  }
}

local win = window.open({
  title: "triangle", width: 640, height: 480, resizable: true
})
local device = gpu.device()
local surface = device:surface(win)

local pipeline = device:render_pipeline({
  shader: colors,
  fragment: {targets: {{format: surface.format}}},
})

local frames = 0
// TRIANGLE_FRAMES=n stops after n frames (for tests)
local limit = os.getenv("TRIANGLE_FRAMES")
for(win.open){
  for(let local e in values(win:events())){
    if(e.type == "key_down" and e.key == "escape"){
      win:close()
    }
  }
  if(not win.open){
    break
  }
  local frame = surface:texture()
  if(frame != null){
    local encoder = device:encoder()
    local pass = encoder:render_pass({
      color_attachments: {
        {view: frame:view(), clear_value: {0.08, 0.08, 0.1, 1}},
      },
    })
    pass:set_pipeline(pipeline)
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
