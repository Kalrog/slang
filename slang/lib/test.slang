// slang/test: a small test framework.
//
// `slang test` loads the test files and calls run_cli(args()): --json
// prints one JSON object per line ({event: "test", path, status, message,
// location}, then {event: "done", passed, failed}) instead of the report,
// --only "group / test" runs the tests under that path (a group's name, a
// test's, or the names from a top group down, joined by " / ").
local json = require("slang/json")
local str = require("slang/string")

local indent = 0
// the options of the run: {json, only}
local options = {}
local func indentStr(){
  local str = ""
  for(local i = 0; i < indent; i = i + 1) {
    str = concat(str, "  ")
  }
  return str
}

local group = {}
func group.new(name){
  local new = {name: name, children: {}, setups: {}, teardowns: {}}
  new.meta = {__index: group}
  return new
}

func group.add_child(self, child){
  print(indentStr(), "Adding child to group ", self.name, " ", child.name, "\n")
  append(self.children, child)
}

// whether a group or test at path runs, by options.only: it is on the way
// to what only names, or inside it
local func wanted(path){
  local only = options.only
  if(only == null){
    return true
  }
  local p = str.join(path, " / ")
  return p == only or str.starts_with(p, concat(only, " / ")) or
    str.starts_with(only, concat(p, " / "))
}

local func child_path(path, name){
  local out = {}
  for(let local p in values(path)){
    append(out, p)
  }
  append(out, name)
  return out
}

func group.run(self, path){
  path = path or {}
  if(self.name != "root"){
    if(not options.json){
      print(indentStr(), "Group: ", self.name, "\n")
    }
    indent = indent + 1
  }
  for(let local child in values(self.children)){
    local cpath = child_path(path, child.name)
    if(wanted(cpath)){
      for(let local setup in values(self.setups)){
        setup()
      }
      pcall(child.run, child, cpath)

      for(let local teardown in values(self.teardowns)){
        teardown()
      }
    }
  }
  if(self.name != "root"){
    indent = indent - 1
  }
}

func group.count(self){
  local succeded = 0
  local failed = 0
  for(let local child in values(self.children)){
    local count = child:count()
    succeded = succeded + count[0]
    failed = failed + count[1]
  }
  return {succeded, failed}
}

local current = group.new("root")
local m = {}

local test = {}

func test.new(name, f){
  local new = {name: name, f: f, succeded: false, ran: false, log: {}}
  new.meta = {__index: test}
  return new
}

func test.run(self, path){
  self.ran = true
  if(not options.json){
    print(indentStr(), "Test: ", self.name)
  }
  local r = pcall(self.f)
  if(let {"ok"} = r){
    self.succeded = true
    if(options.json){
      print(
        json.encode({
          event: "test", path: path or {self.name}, status: "passed"
        }),
        "\n",
      )
    } else {
      print(" Passed\n")
    }
  } else if(let {"err", local e} = r){
    local message = e
    if(type(e) == "table"){
      message = e.message
    }
    if(options.json){
      local event = {
        event: "test",
        path: path or {self.name},
        status: "failed",
        message: string(message),
      }
      if(type(e) == "table" and e.location){
        event.location = {
          origin: e.location.origin,
          line: e.location.line,
          column: e.location.column,
        }
      }
      print(json.encode(event), "\n")
      return null
    }
    print(" Failed\n")
    print(indentStr(), "  Error: ", message)
    if(type(e) == "table" and e.location){
      print(
        " @", e.location.origin, ":", e.location.line, ":", e.location.column
      )
    }
    print("\n")
  }
}

func test.count(self){
  if(not self.ran){
    return {0, 0}
  }
  if(self.succeded){
    return {1, 0}
  } else {
    return {0, 1}
  }
}

func m.group(name, f){
  local g = group.new(name)
  local parent = current
  current = g
  f()
  current = parent
  parent:add_child(g)
}

func m.test(name, f){
  local parent = current
  parent:add_child(test.new(name, f))
}

func m.setup(f){
  append(current.setups, f)
}

func m.teardown(f){
  append(current.teardowns, f)
}

// run([{json, only}]) -> the number of tests that failed
func m.run(opts){
  options = opts or {}
  if(not options.json){
    print("Running tests\n")
  }
  current:run({})
  local stats = current:count()
  local total = stats[0] + stats[1]
  if(options.json){
    print(
      json.encode({event: "done", passed: stats[0], failed: stats[1]}),
      "\n",
    )
    return stats[1]
  }
  print("Tests succeded: ", stats[0], "\n")
  print("Tests failed: ", stats[1], "\n")
  print("Total tests: ", total, "\n")
  if(stats[1] > 0){
    print("Some tests failed\n")
  } else {
    print("All tests passed\n")
  }
  return stats[1]
}

// run_cli(argv) -> whether a test failed: run with the options of `slang
// test` (--json, --only path)
func m.run_cli(argv){
  local opts = {}
  local i = 0
  for(i < len(argv)){
    if(argv[i] == "--json"){
      opts.json = true
    } else if(argv[i] == "--only" and i + 1 < len(argv)){
      i = i + 1
      opts.only = argv[i]
    }
    i = i + 1
  }
  return m.run(opts) > 0
}

return m
