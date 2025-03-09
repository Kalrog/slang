local m = {
  current: group.new('root'),
}

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
  for _, child in self.children {
    for _, setup in self.setups {
      setup()
    }
    child.run()
    for _, teardown in self.teardowns {
      teardown()
    }
  }
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
  local parent = m.current
  m.current = g
  f()
  m.current = parent
  parent.add_child(g)
}

func m.test(name, f) {
  local parent = m.current
  parent.add_child(test.new(name, f))
}

func m.setup(f){
  append(m.current.setups, f)
}

func m.teardown(f){
  append(m.current.teardowns, f)
}


