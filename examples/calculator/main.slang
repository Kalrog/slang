local rl = require("raylib")

//Type Button
local Button = {}

local func init(){
  rl.window.open(400, 600, "Calculator")
}

local func update(){ }

local func draw(){
  rl.draw.clear(rl.RAYWHITE)
}

local func main(){
  init()
  for(not rl.window.should_close){
    rl.drawing{
      update()
      draw()
    }
  }
}

//Button.new(class:table,prop:{width:int,height:int,color?:rl.Color})
func Button.new(class, prop){ }

main()
