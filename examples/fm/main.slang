// slang six: a polyphonic six-operator FM synthesizer in the spirit of the
// classic digital keyboards of the 1980s: 32 algorithms, envelopes of four
// rates and four levels on every operator, an LFO, a pitch envelope,
// velocity and key scaling, sixteen voices, and a bank of 32 patches. The
// sound is computed by kernels (packages/kernel) in an isolate of its own
// (engine.slang under raylib/stream); this program draws the panel.
//
//   make fm           (or: cd examples/fm && slang run main.slang)
//
// Play with the mouse (lower on a key is louder) or the computer keyboard
// (Z S X D C V G B H N J M , and Q 2 W 3 E R 5 T 6 Y 7 U I); left and right
// change the octave, up and down the patch, TAB is the sustain pedal and
// SPACE lets go of everything. Drag any number up or down to change it
// (shift: finely), or turn the mouse wheel over it; click a switch to flip
// it, and an operator in the diagram to mute it. Choosing a patch again
// undoes its edits.
//
// FM_FRAMES=n quits after n frames, FM_DEMO=1 plays chords by itself,
// FM_PATCH=n starts on patch n (1..32), FM_SCREENSHOT=file.png saves the
// last frame. main3d.slang is the same synth as a keyboard in 3D, with a
// hardware panel.
local rl = require("raylib")
local app = require("app")
local panel_mod = require("panel")

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(panel_mod.W, panel_mod.H, "slang six")
rl.set_target_fps(60)
// ESC should not close the synth while it is played
rl.set_exit_key(rl.KEY_NULL)
panel_mod.load_font()
app.start("midi_map.json")
local panel = panel_mod.new(app)

local frame = 0
app.mark_start()
for(not rl.window_should_close() and frame != app.max_frames){
  panel.handle_mouse()
  app.handle_keys()
  app.update(frame)
  rl.begin_drawing()
  panel.draw()
  rl.end_drawing()
  frame = frame + 1
  app.end_frame(frame)
}

panel_mod.unload_font()
app.finish(frame)
rl.close_window()
