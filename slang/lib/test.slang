// slang/test: a small test framework: groups of named tests, set up and
// torn down, run by `slang test`.
//
//   local t = require("slang/test")
//   t.group("math"){
//     t.test("adds"){
//       assert(1 + 1 == 2, "1 + 1")
//     }
//   }
//
// A test passes when its function returns and fails when it raises (a failed
// `assert` or any other error); the report shows the message and where it
// was raised. Registering only collects: `slang test` loads the test
// files, then calls [run_cli] with its arguments, which runs everything
// registered and reports.
//
// With --json, [run] prints one JSON object per line instead of the
// report: {event: "test", path, status, message, location} for each test
// that ran (status "passed" or "failed"; message and location when it
// failed), then {event: "done", passed, failed}. With --only "group /
// test", only the tests under that path run: a group's name, a test's, or
// the names from a top group down, joined by " / ".

// What [run] does.
// type Options = {json?: bool, only?: string}
// [json]: print JSON lines instead of the report
// [only]: the path of the group or test to run, names joined by " / "
local json = require("slang/json")
local str = require("slang/string")

local indent = 0
// the options of the run: {json, only}
local options = {}
local func indent_str(){
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
      print(indent_str(), "Group: ", self.name, "\n")
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
  local succeeded = 0
  local failed = 0
  for(let local child in values(self.children)){
    local count = child:count()
    succeeded = succeeded + count[0]
    failed = failed + count[1]
  }
  return {succeeded, failed}
}

local current = group.new("root")
local m = {}

local test = {}

func test.new(name, f){
  local new = {name: name, f: f, succeeded: false, ran: false, log: {}}
  new.meta = {__index: test}
  return new
}

func test.run(self, path){
  self.ran = true
  if(not options.json){
    print(indent_str(), "Test: ", self.name)
  }
  local r = pcall(self.f)
  if(let {"ok"} = r){
    self.succeeded = true
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
    print(indent_str(), "  Error: ", message)
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
  if(self.succeeded){
    return {1, 0}
  } else {
    return {0, 1}
  }
}

// group(name: string, f: function)
// Registers a group: runs f at once, and the tests, groups, setups and
// teardowns f registers belong to the group. Usually written with a block:
// t.group("name"){ ... }.
func m.group(name, f){
  local g = group.new(name)
  local parent = current
  current = g
  f()
  current = parent
  parent:add_child(g)
}

// test(name: string, f: function)
// Registers a test in the current group; f runs when the tests run.
// Usually written with a block: t.test("name"){ ... }.
func m.test(name, f){
  local parent = current
  parent:add_child(test.new(name, f))
}

// setup(f: function)
// Registers f to run before each test and subgroup of the current group
// (each subgroup once, not before each of its tests).
func m.setup(f){
  append(current.setups, f)
}

// teardown(f: function)
// Registers f to run after each test and subgroup of the current group,
// whether it passed or not.
func m.teardown(f){
  append(current.teardowns, f)
}

// run(opts?: Options) -> int
// Runs the registered tests, prints the report (or JSON lines) and
// returns the number of tests that failed.
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
  print("Tests succeeded: ", stats[0], "\n")
  print("Tests failed: ", stats[1], "\n")
  print("Total tests: ", total, "\n")
  if(stats[1] > 0){
    print("Some tests failed\n")
  } else {
    print("All tests passed\n")
  }
  return stats[1]
}

// run_cli(argv: {string}) -> bool
// [run] with the options of `slang test` read from argv (--json, --only
// path; anything else is ignored); true when a test failed.
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
