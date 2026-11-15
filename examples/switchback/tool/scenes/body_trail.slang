// tool/scenes/body_trail: the truck's body over one of the trail's
// obstacles in the real game: the first section of the Summit Run whose
// name has the given word in it ("Moguls", "Rock", "Washouts",
// "Steps"...), from sixteen meters before it to a little beyond it. The
// bot drives: as carefully as it does ("crawl"), or with the pedal all
// the way down and never a brake ("fast": what a player in a hurry does
// to the suspension).
// Arguments: the section's word (Moguls), crawl or fast (crawl), seed
// (25), then the layers to hear (the body alone when none are given).
local str = require("slang/string")
local math = require("slang/math")

return func(kit, args){
  local world = require("game/world")
  local bot = require("game/bot")
  local explore = require("game/explore")
  local director = require("sound/director")
  local mixer = require("sound/mixer")
  local word = args[0] or "Moguls"
  local fast = (args[1] or "crawl") == "fast"
  local only = {}
  for(local i = 3; i < len(args); i = i + 1){
    append(only, args[i])
  }
  if(len(only) == 0){
    only = {"body"}
  }
  local w = world.new({seed: to_int(str.to_number(args[2] or "25"))})
  local section = null
  for(let local s in values(w.trail.sections)){
    if(section == null and str.contains(s.name, word)){
      section = s
    }
  }
  if(section == null){
    print("body_trail: no section named ", word, " on this trail\n")
    section = {name: "the trail", from: 300, to: 340}
  }
  local driver = bot.new()
  driver.index = to_int(math.max(section.from - 16, 8) / 2)
  world.recover(w, driver.index)
  // (as long as the bot takes at a crawl, half of that in a hurry)
  local seconds = (section.to - section.from + 30) / (if(fast){ 5 } else { 2 }) +
    3
  print(
    "body_trail: ", section.name, ", ", to_int(section.from), " to ",
    to_int(section.to), " m, ", to_int(seconds), " s\n"
  )
  local rules = explore.new(w, {keep: false})
  local sound = director.offline()
  local costs = mixer.costs()
  local block = mixer.new(sound.shared.values, sound.shared.events, {
    sample_rate: kit.RATE,
    block: kit.BLOCK,
    only: only,
    costs: costs,
  })
  local r = kit.run(seconds, block, func(t, dt){
    local input = if(t < 2.2){ {} } else { driver:drive(w, dt) }
    if(fast and t >= 2.2){
      input.forward = 1
      input.back = 0
    }
    world.step(w, input, dt)
    local events = explore.step(rules, w, input, dt)
    sound:engine(t > 0.5)
    sound:frame({
      world: w,
      car: w.car,
      view: kit.behind(w.car, 7.6, 2.5),
      dt: dt,
      damage: rules.damage,
      input: input,
      events: events,
      screen: "drive",
    })
  })
  r.costs = costs
  world.destroy(w)
  return r
}
