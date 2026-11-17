// Doubles a list of numbers on the GPU with a WGSL compute shader and
// reads the result back. No window needed.
//   cd packages/gpu && ../../bin/slang run examples/compute.slang
local gpu = require("gpu")
local math = require("slang/math")

local device = gpu.device()
print(
  "adapter: ", device.adapter.info.device, " (",
  device.adapter.info.backend_type, ")\n"
)

local shader = device:shader("""
  @group(0) @binding(0) var<storage, read_write> v: array<f32>;

  @compute @workgroup_size(64)
  fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x < arrayLength(&v)) {
      v[id.x] = v[id.x] * 2.0;
    }
  }""")
local pipeline = device:compute_pipeline({shader: shader})

local n = 1000
local input = {}
for(local i = 0; i < n; i = i + 1){
  append(input, i)
}
local data = device:buffer({contents: input, usage: "storage|copy_src"})

local encoder = device:encoder()
local pass = encoder:compute_pass()
pass:set_pipeline(pipeline)
pass:set_bind_group(0, device:bind_group({
  layout: pipeline:get_bind_group_layout(0),
  entries: {{binding: 0, resource: data}},
}))
pass:dispatch_workgroups(math.floor((n + 63) / 64) | 0)
pass:finish()
device.queue:submit(encoder:finish())

local out = data:read("float")
print(out[0], " ", out[1], " ", out[2], " ... ", out[n - 1], "\n")
