// navigate/classes_main: uses navigate/classes
local classes = require("test/navigate/classes")
local Vec = classes.Vec
local Body = classes.Body

local b = Body.new({at: Vec.new(0, 0)})
b:start()
local v = b.speed + Vec.new(1, 1)
local w = if(v != null){ b:where() } else { null }
local u = -v
print(v:length(), w:length(), u:length(), b:near(b))
print(b:carry({load: v}))
