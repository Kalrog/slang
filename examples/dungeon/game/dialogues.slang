// Conversations (dsl/dialogue). They run as coroutines while the game keeps
// drawing; `flags` is the game's global flag table.
extension "dsl/dialogue"
local world = require("engine/world")

dialogue elder {
  say "Ah, a visitor. Few come down here these days."
  choice {
    "Where am I?" => {
      say "The old mines. Goblins moved in when the dwarves left."
      say "The stairs lead deeper. Find the key to open the door."
    }
    "How do I fight?" => {
      say "Walk into a monster to strike it. They strike back, so mind your hearts."
      say "Potions heal. There is a sword somewhere below, if you can reach it."
    }
    "I'll manage." => {
      say "Suit yourself."
    }
  }
  if(world.state.player.keys > 0){
    say "You already have the key! Off you go, then."
  }
  flags.met_elder = true
}

dialogue sage {
  say "You made it this far? Impressive."
  if(flags.met_elder){
    say "My brother upstairs talks too much, doesn't he?"
  }
  say "The hoard lies beyond. Take what you can carry."
}
