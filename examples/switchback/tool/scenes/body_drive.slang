// tool/scenes/body_drive: the truck's body in the real game. The bot
// steers; the pedal is the bot's with a heavy foot ("heavy"), or all the
// way down the whole time, with never a brake ("wild": the truck leaves
// the trail, lands hard, hits trees, breaks down and is towed), which is
// where the knocks, the rattles and the bushes are.
// Arguments: seed (25), from (m along the trail, 2500), seconds (60),
// heavy or wild (wild), then the layers to hear (the body alone when
// none are given).
local str = require("slang/string")

return func(kit, args){
  local only = {}
  for(local i = 4; i < len(args); i = i + 1){
    append(only, args[i])
  }
  if(len(only) == 0){
    only = {"body"}
  }
  local wild = (args[3] or "wild") == "wild"
  return kit.drive({
    seed: to_int(str.to_number(args[0] or "25")),
    from: str.to_number(args[1] or "2500"),
    seconds: str.to_number(args[2] or "60"),
    heavy: true,
    only: only,
    input: func(t, world, input){
      if(wild and t > 2.2){
        input.forward = 1
        input.back = 0
      }
      return input
    },
  })
}
