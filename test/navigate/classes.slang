// navigate/classes: classes written as metatables, with no type
// declarations (the language server finds them by their tables)
local Vec = {}
Vec.__index = Vec

// new(x: number, y: number) -> Vec
func Vec.new(x, y){
  return {x: x, y: y, @meta: Vec}
}

// length() -> number
func Vec.length(self){
  return self.x + self.y
}

Vec.__add = func(a, b){
  return Vec.new(a.x + b.x, a.y + b.y)
}

Vec.__unm = func(a){
  return Vec.new(-a.x, -a.y)
}

local Body = {}
Body.__index = Body

// new(options) -> Body
func Body.new(options){
  return {at: options.at, @meta: Body}
}

func Body.start(self){
  self.speed = Vec.new(0, 0)
}

// where() -> Vec
func Body.where(self){
  return self.at + self.speed
}

// near(other: Body) -> bool
func Body.near(self, other){
  return other.at.x == self.at.x
}

func Body.carry(self, ctx){
  return ctx.load
}

return {Vec: Vec, Body: Body}
