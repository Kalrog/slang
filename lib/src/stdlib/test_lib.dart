import 'package:slang/slang.dart';
import 'package:slang/src/stdlib/package_lib.dart';

class SlangTestLib {
  static const testLib = """local indent = 0
local func indentStr(){
  local str = ""
  for (local i = 0; i < indent; i = i + 1) {
    str = concat(str, "  ")
  }
  return str
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
  if (self.name != "root") {
    print(indentStr(),"Group: ",self.name,"\n")
    indent = indent + 1
  }
  for (local child in values(self.children)) {
    for (local setup in values(self.setups)) {
      setup()
    }
    pcall(child.run,child)

    for (local teardown in values(self.teardowns)) {
      teardown()
    }
  }
  if (self.name != "root") {
    indent = indent - 1
  }
}

func group.count(self) {
  local succeded = 0
  local failed = 0
  for (local child in values(self.children)) {
    local count = child:count()
    succeded = succeded + count[0]
    failed = failed + count[1]
  } 
  return {succeded,failed}
}

local current= group.new("root")
local m = {

}

local test = {}

func test.new(name, f){
  local new = {
    name: name,
    f: f,
    succeded: false,
  }
  new.meta = {__index: test}
  return new
}

func test.run(self){
  print(indentStr(),"Test: ",self.name)
  local r = pcall(self.f)
  if(let {"ok"} = r){
    print(" Passed\n")
    self.succeded = true
  }else if (let {"err",local e} = r){
    print(" Failed\n")
    print(indentStr(),"  Error: ",e.message)
    if(e.location){
      print(" @",e.location.origin,":",e.location.line,":",e.location.column)
    }
    print("\n")
  }
}

func test.count(self){
  if (self.succeded) {
    return {1,0}
  }else{
    return {0,1}
  }
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
  append(current.setups, f)
}

func m.teardown(f){
  append(current.teardowns, f)
}

func m.run(){
  print("Running tests\n")
  current:run()
  local stats = current:count()
  local total = stats[0] + stats[1]
  print("Tests succeded: ",stats[0],"\n")
  print("Tests failed: ",stats[1],"\n")
  print("Total tests: ",total,"\n")
  if(stats[1] > 0){
    print("Some tests failed\n")
  }else{
    print("All tests passed\n")
  }
}

return m
""";

  static void register(SlangVm vm) {
    SlangPackageLib.preloadModule(vm, "slang/test", testLib);
  }
}
