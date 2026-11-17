// A unit of the tests' own, made of a dsp program: studio/program's effect.
local program = require("studio/program")

return program.effect(require("test/programs/tilt"), {name: "tilt"})
