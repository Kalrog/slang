// studio/units/wind: wind: noise through a resonant bandpass at the note (q, breath).
// A dsp program (units/programs/wind.dsp) through studio/program.
//
//   s:track("wind", "wind")
local program = require("studio/program")

return program.instrument(require("studio/units/programs/wind"), {name: "wind"})
