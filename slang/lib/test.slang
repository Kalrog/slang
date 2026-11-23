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
// `assert` or any other error); the report shows the message, where it was
// raised and the calls that led there in the test's own code. A test that
// calls [skip] is skipped. Registering only collects: `slang test` loads
// the test files ([run_files]), then runs everything registered and
// reports. Tests can also live in the file they test, as `group(name){ ...
// }` and `test(name){ ... }` statements that only a test run compiles (see
// extensions/inline_test).
//
// Nothing that goes wrong stops the run: a file that does not load, a
// group whose code raises while it registers, a setup or a teardown that
// raises, each is a failure in the report, and the other tests still run.
//
// With --json, [run] prints one JSON object per line instead of the
// report: {event: "test", path, status, message, location, file, ms} for
// each test that ran (status "passed", "failed" or "skipped"; message and
// location when it failed or was skipped; file when a test file registered
// it), then {event: "done", passed, failed, skipped, ms}. With --only
// "group / test", only the tests under that path run: a group's name, a
// test's, or the names from a top group down, joined by " / ".

// What [run] does.
// type Options = {json?: bool, only?: string}
// [json]: print JSON lines instead of the report
// [only]: the path of the group or test to run, names joined by " / "
local json = require("slang/json")
local str = require("slang/string")
local time = require("slang/time")

// a test slower than this many ms shows its time in the report
local SLOW_MS = 1000
// the most frames of a failure's stack the report shows
local MAX_FRAMES = 8

local indent = 0
// the options of the run: {json, only}
local options = {}
// the test file being loaded (run_files): what its tests and groups record
local current_file = null
// whether anything ran (for --only that matches nothing)
local ran_any = false

local func indent_str(){
  local s = ""
  for(local i = 0; i < indent; i = i + 1) {
    s = concat(s, "  ")
  }
  return s
}

// the frames of an error's stack that are in the tested code: not the
// natives, not this file (the runner), at most MAX_FRAMES
local func frames_of(e){
  local out = {}
  if(e == null or type(e.stack) != "string"){
    return out
  }
  for(let local line in values(str.lines(e.stack))){
    local l = str.trim(line)
    if(str.starts_with(l, "at ") and not str.contains(l, "[native") and
      len(out) < MAX_FRAMES){
      // (the runner calls the test: what is below it is not the test's)
      if(str.contains(l, "slang/test:")){
        break
      }
      append(out, l)
    }
  }
  return out
}

local func location_of(e){
  if(e == null or e.location == null){
    return null
  }
  return {
    origin: e.location.origin, line: e.location.line,
    column: e.location.column,
  }
}

// reports one result: status "passed", "failed" or "skipped"; e the error
// (failed) or the skip (skipped); prefix comes before a failure's message
// ("setup failed: ")
local func report(path, name, status, e, file, ms, prefix){
  local message = null
  if(e != null){
    // (a skip says why; anything raised has a message, a plain string too)
    local text = error.message(e)
    if(status == "skipped" and type(e) == "table" and e.reason != null){
      text = e.reason
    }
    message = concat(prefix or "", text)
  }
  if(options.json){
    local event = {event: "test", path: path, status: status, ms: ms}
    if(file != null){
      event.file = file
    }
    if(message != null){
      event.message = message
      local where = location_of(e)
      if(where != null and status == "failed"){
        event.location = where
      }
    }
    print(json.encode(event), "\n")
    return null
  }
  local timing = ""
  if(ms != null and ms >= SLOW_MS){
    timing = concat(" (", string(to_int(ms)), " ms)")
  }
  if(status == "passed"){
    print(indent_str(), "Test: ", name, " Passed", timing, "\n")
    return null
  }
  if(status == "skipped"){
    print(indent_str(), "Test: ", name, " Skipped: ", message, "\n")
    return null
  }
  print(indent_str(), "Test: ", name, " Failed", timing, "\n")
  print(indent_str(), "  Error: ", message)
  local where = location_of(e)
  if(where != null){
    print(" @", where.origin, ":", where.line, ":", where.column)
  }
  print("\n")
  // the calls that led there, when there was more than the raise itself
  local frames = frames_of(e)
  if(len(frames) > 1){
    for(let local f in values(frames)){
      print(indent_str(), "    ", f, "\n")
    }
  }
}

local func child_path(path, name){
  local out = {}
  for(let local p in values(path)){
    append(out, p)
  }
  append(out, name)
  return out
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

// ------------------------------------------------------------ tests

local test = {}

func test.new(name, f){
  local new = {
    name: name, f: f, status: null, ran: false, file: current_file
  }
  new.@meta = {__index: test}
  return new
}

func test.run(self, path){
  self.ran = true
  ran_any = true
  local t0 = time.clock()
  local e = null
  try {
    self.f()
  } catch(local raised) {
    e = raised
  }
  local ms = to_int(time.clock() - t0)
  if(e == null){
    self.status = "passed"
  } else if(type(e) == "table" and e.skipped == true){
    self.status = "skipped"
  } else {
    self.status = "failed"
  }
  self.error = e
  report(path, self.name, self.status, e, self.file, ms)
}

// a test that cannot run (its group's setup failed): failed with e
func test.fail(self, path, prefix, e){
  self.ran = true
  ran_any = true
  self.status = "failed"
  self.error = e
  report(path, self.name, "failed", e, self.file, null, prefix)
}

func test.count(self){
  if(not self.ran){
    return {0, 0, 0}
  }
  if(self.status == "passed"){
    return {1, 0, 0}
  }
  if(self.status == "skipped"){
    return {0, 0, 1}
  }
  return {0, 1, 0}
}

// ------------------------------------------------------------ groups

local group = {}
func group.new(name){
  local new = {
    name: name, children: {}, setups: {}, teardowns: {}, problems: {},
    file: current_file
  }
  new.@meta = {__index: group}
  return new
}

func group.add_child(self, child){
  append(self.children, child)
}

// a failure that is not a test's (a teardown's): reported under path and
// counted
func group.problem(self, path, name, prefix, e){
  append(self.problems, {name: name, error: e})
  ran_any = true
  report(child_path(path, name), name, "failed", e, self.file, null, prefix)
}

func group.run(self, path){
  path = path or {}
  local top = self.name == "root"
  if(not top){
    if(not options.json){
      print(indent_str(), "Group: ", self.name, "\n")
    }
    indent = indent + 1
  }
  for(let local child in values(self.children)){
    local cpath = child_path(path, child.name)
    if(wanted(cpath)){
      // a file's tests under a heading naming the file
      if(top and child.file != null and child.file != self.last_file and
        not options.json){
        print("File: ", child.file, "\n")
        self.last_file = child.file
      }
      local setup_error = null
      for(let local setup in values(self.setups)){
        if(setup_error == null){
          try { setup() } catch(local e) { setup_error = e }
        }
      }
      if(setup_error != null){
        child:fail(cpath, "setup failed: ", setup_error)
      } else {
        child:run(cpath)
      }
      for(let local teardown in values(self.teardowns)){
        try { teardown() } catch(local e) {
          self:problem(path, concat(child.name, " (teardown)"), "teardown failed: ", e)
        }
      }
    }
  }
  if(not top){
    indent = indent - 1
  }
}

// a group whose setup failed: each of its tests fails with e
func group.fail(self, path, prefix, e){
  if(not options.json){
    print(indent_str(), "Group: ", self.name, "\n")
  }
  indent = indent + 1
  for(let local child in values(self.children)){
    local cpath = child_path(path, child.name)
    if(wanted(cpath)){
      child:fail(cpath, prefix, e)
    }
  }
  indent = indent - 1
}

func group.count(self){
  local passed = 0
  local failed = len(self.problems)
  local skipped = 0
  for(let local child in values(self.children)){
    local count = child:count()
    passed = passed + count[0]
    failed = failed + count[1]
    skipped = skipped + count[2]
  }
  return {passed, failed, skipped}
}

// ------------------------------------------------------------ the API

local current = group.new("root")
local m = {}

// group(name: string, f: function)
// Registers a group: runs f at once, and the tests, groups, setups and
// teardowns f registers belong to the group. Usually written with a block:
// t.group("name"){ ... }. When f raises, the group keeps what it
// registered until then and the error is one of its failures.
func m.group(name, f){
  local g = group.new(name)
  local parent = current
  current = g
  local err = null
  try { f() } catch(local e) { err = e }
  current = parent
  if(err != null){
    // (raised again when the tests run, the error keeps where it was
    // raised)
    g:add_child(test.new("(the group's code)", func(){ raise(err) }))
  }
  parent:add_child(g)
}

// test(name: string, f: function)
// Registers a test in the current group; f runs when the tests run.
// Usually written with a block: t.test("name"){ ... }.
func m.test(name, f){
  current:add_child(test.new(name, f))
}

// setup(f: function)
// Registers f to run before each test and subgroup of the current group
// (each subgroup once, not before each of its tests). When it raises, the
// test (or every test of the subgroup) fails without running.
func m.setup(f){
  append(current.setups, f)
}

// teardown(f: function)
// Registers f to run after each test and subgroup of the current group,
// whether it passed or not. When it raises, that is a failure of its own
// in the report.
func m.teardown(f){
  append(current.teardowns, f)
}

// skip(reason: string)
// Ends the test that calls it as skipped, not failed: for a test that
// cannot run here (a platform without what it needs).
//   if(windows){ t.skip("runs /bin/sh") }
func m.skip(reason){
  raise(error.new(error.kinds.error, concat("skipped: ", reason), {
    skipped: true, reason: reason
  }))
}

// raises(f: function, expected?: string) -> Error
// Calls f and returns the error it raises; fails the test when f returns
// instead, or when expected is given and is neither the error's kind nor
// a part of its message.
//   local e = t.raises(func(){ to_int({}) }, "argument")
//   t.raises(func(){ json.decode("{") }, "JSON value expected")
func m.raises(f, expected){
  local raised = null
  local returned = false
  try {
    f()
    returned = true
  } catch(local e) {
    raised = e
  }
  if(returned){
    raise(error.new(error.kinds.assertion,
      "expected an error, but the function returned"))
  }
  if(expected != null and raised.kind != expected and
    str.index_of(error.message(raised), expected) < 0){
    raise(error.new(error.kinds.assertion, concat(
      "expected an error with ", expected, ", got: ", error.message(raised))))
  }
  return raised
}

// run(opts?: Options) -> int
// Runs the registered tests, prints the report (or JSON lines) and
// returns the number of tests that failed (with an --only that matches no
// test, 1).
func m.run(opts){
  options = opts or {}
  local t0 = time.clock()
  if(not options.json){
    print("Running tests\n")
  }
  current:run({})
  local stats = current:count()
  local ms = to_int(time.clock() - t0)
  local total = stats[0] + stats[1] + stats[2]
  local failed = stats[1]
  local no_match = options.only != null and not ran_any
  if(no_match){
    failed = failed + 1
  }
  if(options.json){
    print(
      json.encode({
        event: "done", passed: stats[0], failed: failed, skipped: stats[2],
        ms: ms,
      }),
      "\n",
    )
    return failed
  }
  if(no_match){
    print("No test matches --only ", options.only, "\n")
  }
  print("Tests succeeded: ", stats[0], "\n")
  print("Tests failed: ", stats[1], "\n")
  if(stats[2] > 0){
    print("Tests skipped: ", stats[2], "\n")
  }
  print("Total tests: ", total, "\n")
  print("Time: ", ms, " ms\n")
  if(failed > 0){
    print("Some tests failed\n")
  } else {
    print("All tests passed\n")
  }
  return failed
}

// read_options(argv: {string}) -> Options
// The options of `slang test` in argv (--json, --only path; anything else
// is not an option of the run).
local func read_options(argv){
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
  return opts
}

// run_cli(argv: {string}) -> bool
// [run] with the options of `slang test` read from argv (--json, --only
// path; anything else is ignored); true when a test failed.
func m.run_cli(argv){
  return m.run(read_options(argv)) > 0
}

// run_files(files: {string}, argv: {string}) -> bool
// What `slang test` does: loads each test file (compiled as the compiler
// compiles a test run's files), then [run_cli]. A file that does not load
// (it does not compile, or raises while it registers its tests) is a
// failed test named after it, and the other files still run.
func m.run_files(files, argv){
  local compiler = require("slang/compiler")
  for(let local path in values(files)){
    current_file = path
    local err = null
    try {
      local f = compiler.load_main(path)
      f()
    } catch(local e) {
      err = e
    }
    if(err != null){
      current:add_child(test.new(concat("(loading ", path, ")"), func(){ raise(err) }))
    }
  }
  current_file = null
  return m.run_cli(argv)
}

return m
