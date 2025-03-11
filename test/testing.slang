local group = {}
func group.new(name){
  local new = {
    name: name,
    children: {},
    setups: {},
    teardowns: {},
  }
  new.meta = {__index: group}
  return new
}

func group.add_child(self,child){
  append(self.children, child)
}

func group.run(self){
  for (child in values(self.children)) {
    for (setup in values(self.setups)) {
      setup()
    }
    child.run()
    for (teardown in values(self.teardowns)) {
      teardown()
    }
  }
}

local current= group.new("root")
local m = {

}



local test = {}

func test.new(name, f){
  local new = {
    name: name,
    f: f,
  }
  new.meta = {__index: test}
  return new
}

func test.run(self){
  self.f()
}


func m.group(name, f) {
  local g = group.new(name)
  local parent = current
  current = g
  f()
  current = parent
  parent:add_child(g)
}

func m.test(name, f) {
  local parent = current
  parent:add_child(test.new(name, f))
}

func m.setup(f){
  append(m.current.setups, f)
}

func m.teardown(f){
  append(m.current.teardowns, f)
}

func m.run(){
  m.current.run()
}

return m

