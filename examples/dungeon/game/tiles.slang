// Tiles of the mines.
extension "dsl/level"
local events = require("engine/events")

tile wall {solid: true, sprite: "wall"}
tile floor {sprite: "floor"}
tile stairs {
  sprite: "stairs",
  on_enter: func(who, x, y){
    if(type(who) == "Player"){
      events.emit({kind: "exit", x: x, y: y})
    }
  },
}
