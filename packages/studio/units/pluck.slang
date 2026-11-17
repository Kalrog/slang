// studio/units/pluck: a plucked string (Karplus-Strong), by its damping and brightness.
// A dsp program (units/programs/pluck.dsp) through studio/program.
//
//   s:track("pluck", "pluck")
local program = require("studio/program")

return program.instrument(require("studio/units/programs/pluck"), {
  name: "pluck",
})
