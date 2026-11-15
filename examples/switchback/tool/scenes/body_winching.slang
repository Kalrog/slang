// tool/scenes/body_winching: the winch in the real game: the truck
// stands on the trail (the hand brake on), at 3 s the hook is set (on a
// tree if one stands ahead, else on a ground anchor), the line pulls the
// truck against its brakes, at 9 s the hand brake is let go and the
// truck is pulled along, and at 14 s the line is unhooked and runs in.
// Arguments: seed (25), from (m along the trail, 2500), then the layers
// to hear (the body alone when none are given).
local str = require("slang/string")

return func(kit, args){
  local winch = require("game/winch")
  local only = {}
  for(local i = 2; i < len(args); i = i + 1){
    append(only, args[i])
  }
  if(len(only) == 0){
    only = {"body"}
  }
  local stage = 0
  return kit.drive({
    seed: to_int(str.to_number(args[0] or "25")),
    from: str.to_number(args[1] or "2500"),
    seconds: 18,
    only: only,
    input: func(t, w, input){
      return {hand_brake: t < 9, steer: 0}
    },
    each: func(t, w, sound){
      if(t >= 3 and stage == 0){
        stage = 1
        print("body_winching: hooked to ", string(winch.attach(w)), "\n")
      }
      if(t >= 14 and stage == 1){
        stage = 2
        winch.release(w)
      }
    },
  })
}
