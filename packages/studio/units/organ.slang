// studio/units/organ: a drawbar organ: four sines at 1, 2, 3 and 4 times the pitch (bar_8, bar_4,
// bar_2_2_3, bar_2) and a tremolo.
// A dsp program (units/programs/organ.dsp) through studio/program.
//
//   s:track("organ", "organ")
local program = require("studio/program")

return program.instrument(require("studio/units/programs/organ"), {
  name: "organ",
})
