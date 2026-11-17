// studio/events: what the program's side and the engine share, and the
// timed instructions that cross between them.
//
// Everything the two sides share is numbers in shared buffers
// (events.state()), so the engine can run in an isolate of its own (the
// audio stream's) or in the program's (offline) without either side
// knowing which:
//
//   values   the parameters as they were set, one cell each. A unit's
//            parameters are a run of cells from its base.
//   eff      the same cells as the sound uses them: modulated by the
//            LFOs. A unit reads these.
//   ring     the instructions, ES doubles each: time (samples of the
//            engine's clock), kind, target, a, b, c
//   ctl      the ring's counters, the engine's clock, its load
//   meters   METER cells per strip slot: peak left, peak right, voices
//   scope    the last SCOPE samples of the master (left + right, halved);
//            ctl[SCOPE_AT] is where the next goes
//
// An instruction applies when the engine's clock reaches its time, to the
// sample: the engine renders up to it, applies it, and goes on. A time of
// 0 (or any time already past) means now.
local buffer = require("slang/buffer")

local events = {}

events.CELLS = 16384 // parameter cells in all
events.RING = 4096 // instructions the ring holds
events.ES = 6 // doubles per instruction
events.STRIPS = 64 // strip slots (tracks, buses, the master)
events.METER = 4 // cells per strip slot in meters
events.SCOPE = 2048 // samples of the master kept for drawing

// the kinds of instruction
events.kinds = {
  NOTE_ON: 0, // target: track slot; a: note, b: velocity (0..1)
  NOTE_OFF: 1, // target: track slot; a: note
  PARAM: 2, // target: cell; a: value
  NEXT: 3, // target: track slot; a: the instrument's parameter, b:
  // value. It holds for the next NOTE_ON of the track only.
  CONTROL: 4, // target: track slot; a: which (events.controls), b: value
  HUSH: 5, // target: track slot, or -1 for all: every note released
  PANIC: 6, // target: track slot, or -1 for all: silence at once
}

// what a CONTROL instruction moves
events.controls = {
  BEND: 0, // -1..1: the pitch wheel
  MOD: 1, // 0..1: the mod wheel
  SUSTAIN: 2, // 0 or 1: the pedal
}

// the cells of ctl
events.ctl = {
  WRITE: 0, // instructions written (the program's side counts)
  READ: 1, // instructions taken (the engine counts)
  PLAYED: 2, // the engine's clock: samples rendered so far
  SCOPE_AT: 3, // where the scope's next sample goes
  DROPPED: 4, // instructions that found the ring full
  SIZE: 8,
}

// the cells of a strip slot in meters
events.meter = {LEFT: 0, RIGHT: 1, VOICES: 2, REDUCTION: 3}

// state(sample_rate: int) -> State
// The shared buffers of one studio.
// type State = {sample_rate: int, values: Buffer, eff: Buffer,
//   ring: Buffer, ctl: Buffer, meters: Buffer, scope: Buffer}
func events.state(sample_rate){
  return {
    sample_rate: sample_rate,
    values: buffer.shared("double", events.CELLS),
    eff: buffer.shared("double", events.CELLS),
    ring: buffer.shared("double", events.RING * events.ES),
    ctl: buffer.shared("double", events.ctl.SIZE),
    meters: buffer.shared("double", events.STRIPS * events.METER),
    scope: buffer.shared("float", events.SCOPE),
  }
}

// send(state: State, time: number, kind: int, target: int, a?: number,
//   b?: number, c?: number) -> bool
// An instruction into the ring; false when the ring is full (the
// instruction is dropped and ctl[DROPPED] counts it). One side writes:
// the program's.
func events.send(state, time, kind, target, a, b, c){
  local ctl = state.ctl
  local w = to_int(ctl[0])
  local r = to_int(ctl[1])
  if(w - r >= events.RING){
    ctl[4] = ctl[4] + 1
    return false
  }
  local base = (w % events.RING) * events.ES
  local ring = state.ring
  ring[base] = time
  ring[base + 1] = kind
  ring[base + 2] = target
  ring[base + 3] = a or 0.0
  ring[base + 4] = b or 0.0
  ring[base + 5] = c or 0.0
  ctl[0] = w + 1
  return true
}

// room(state: State) -> int
// How many more instructions the ring takes right now.
func events.room(state){
  return events.RING - (to_int(state.ctl[0]) - to_int(state.ctl[1]))
}

return events
