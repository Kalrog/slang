// tool/scenes/drive: the game as it sounds: the bot drives the Summit Run
// and the mixer renders what the camera behind the truck hears (stereo).
// Arguments: seed (7), from (m along the trail, 0), seconds (30), then
// "heavy" for a heavy foot (the bot's gas always all of it), and layers
// to hear alone ("engine tires").
local str = require("slang/string")

return func(kit, args){
  local only = null
  local heavy = false
  for(local i = 3; i < len(args); i = i + 1){
    if(args[i] == "heavy"){
      heavy = true
    } else {
      only = only or {}
      append(only, args[i])
    }
  }
  return kit.drive({
    seed: to_int(str.to_number(args[0] or "7")),
    from: str.to_number(args[1] or "0"),
    seconds: str.to_number(args[2] or "30"),
    heavy: heavy,
    only: only,
  })
}
