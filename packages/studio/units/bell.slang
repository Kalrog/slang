// studio/units/bell: a two-operator FM bell, by its ratio, index and decay.
// A dsp program (units/programs/bell.dsp) through studio/program.
//
//   s:track("bell", "bell")
local program = require("studio/program")

return program.instrument(require("studio/units/programs/bell"), {name: "bell"})
