# Drawing on the GPU, into a notebook

A notebook has no window, but the GPU does not need one: it can draw into
a texture, copy the texture into a buffer, and the buffer's bytes become
an image with `nb.pixels`.

This needs a kernel on this machine (`slang notebook`): slang in the page
has no `gpu` package.

```slang
extension "gpu/syntax"
local gpu = require("gpu")
local nb = require("notebook")

local device = gpu.device()
device.adapter.info.device
```

## A texture to draw into, and a buffer to read it from

The texture is what the GPU draws into (`render_attachment`) and copies
out of (`copy_src`). A copy into a buffer goes a row at a time, and every
row starts at a multiple of 256 bytes, so a row of the buffer can be
longer than a row of the image.

```slang
local width = 300
local height = 200

local color_tex = device:texture({
  size: {width: width, height: height},
  format: "rgba8unorm",
  usage: "render_attachment|copy_src",
})

// 4 bytes a pixel, rounded up to the next multiple of 256
local padded_bytes_per_row = (width * 4 + 255) & ~255
local map_buffer = device:buffer({
  size: padded_bytes_per_row * height,
  usage: "map_read|copy_dst",
})
padded_bytes_per_row
```

What the texture holds after a pass, as an image: copy it into the
buffer, wait for the GPU, read the bytes and look each pixel up.

```slang
local func snapshot(encoder){
  encoder:copy_texture_to_buffer(
    {texture: color_tex},
    {
      buffer: map_buffer,
      layout: {
        bytes_per_row: padded_bytes_per_row,
        rows_per_image: color_tex.height,
      },
    },
    {
      width: color_tex.width,
      height: color_tex.height,
      depth_or_array_layers: 1,
    },
  )
  device.queue:submit(encoder:finish())
  device:poll(true)

  local host_buffer = map_buffer:read()
  return nb.pixels(color_tex.width, color_tex.height, func(x, y){
    local at = x * 4 + y * padded_bytes_per_row
    return {
      host_buffer[at] / 255,
      host_buffer[at + 1] / 255,
      host_buffer[at + 2] / 255,
    }
  })
}
```

## A triangle

The shader is WGSL in a `wgsl` block. The pipeline draws into the
texture's format, and the pass clears the texture before it draws.

```slang
wgsl colors {
  struct Out {
    @builtin(position) position: vec4f,
    @location(0) color: vec3f,
  }

  @vertex
  fn vs(@builtin(vertex_index) i: u32) -> Out {
    var points = array(vec2f(0.0, 0.7), vec2f(-0.7, -0.6), vec2f(0.7, -0.6));
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

local triangle = device:render_pipeline({
  shader: colors,
  fragment: {targets: {{format: "rgba8unorm"}}},
})

local encoder = device:encoder()
local pass = encoder:render_pass({
  color_attachments: {
    {view: color_tex:view(), clear_value: {0.08, 0.08, 0.1, 1}},
  },
})
pass:set_pipeline(triangle)
pass:draw(3)
pass:finish()
snapshot(encoder)
```

## A picture from a fragment shader

One triangle that covers the texture, and a colour for every pixel worked
out from where it is. The uniform `t` is set from slang: run the cell
again with another `t` for another picture.

```slang
wgsl rings {
  struct Params {
    t: f32,
  }
  @group(0) @binding(0) var<uniform> p: Params;

  @vertex
  fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    var points = array(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    return vec4f(points[i], 0.0, 1.0);
  }

  @fragment
  fn fs(@builtin(position) at: vec4f) -> @location(0) vec4f {
    let uv = (at.xy - vec2f(150.0, 100.0)) / 100.0;
    let r = length(uv);
    let a = atan2(uv.y, uv.x);
    let wave = 0.5 + 0.5 * sin(r * 18.0 - p.t * 3.0 + 4.0 * sin(a * 3.0 + p.t));
    let glow = exp(-r * 1.6);
    let c = vec3f(0.95, 0.45, 0.2) * wave + vec3f(0.2, 0.35, 0.9) * (1.0 - wave);
    return vec4f(c * (0.25 + glow), 1.0);
  }
}

local pattern = device:render_pipeline({
  shader: rings,
  fragment: {targets: {{format: "rgba8unorm"}}},
})
local params = device:buffer({type: rings.Params, usage: "uniform|copy_dst"})
local bind_group = pattern:bind({p: params})

local func draw_rings(t){
  params:write(rings.Params:new({t: t}))
  local encoder = device:encoder()
  local pass = encoder:render_pass({
    color_attachments: {{view: color_tex:view(), clear_value: {0, 0, 0, 1}}},
  })
  pass:set_pipeline(pattern)
  pass:set_bind_group(0, bind_group)
  pass:draw(3)
  pass:finish()
  return snapshot(encoder)
}

draw_rings(0.5)
```

The same pipeline, three moments:

```slang
nb.display(draw_rings(1.5), draw_rings(2.5), draw_rings(3.5))
```

With a slider instead: `nb.interact` draws the picture again each time
it moves.

```slang
nb.interact({t: nb.slider({min: 0.0, max: 6.0, value: 1.0})}, func(v){
  return draw_rings(v.t)
})
```
