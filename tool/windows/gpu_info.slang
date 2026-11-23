// the GPU WebGPU picks: what the report says about the graphics
local gpu = require("gpu")
local device = gpu.device()
local info = device.adapter.info
print("gpu: ", info.device, " (", info.backend_type, ", ", info.vendor or "", ")\n")
