// slang test: --json and --only, its exit code, and a run that goes on
// past what goes wrong (a file that does not load, a failing setup,
// teardown or group, a skipped test)
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local time = require("slang/time")
local json = require("slang/json")

local dir = concat(
  os.temp_dir(), "/slang-test-cli-", string(to_int(time.now()))
)
local slang = os.executable()

local func write(name, lines){
  os.mkdir_all(dir)
  os.write_file(concat(dir, "/", name), concat(str.join(lines, "\n"), "\n"))
}

// `slang test --json args...`: {status, events (by path " / "), done}
local func run_json(...arguments){
  local argv = {slang, "test", "--json"}
  for(let local a in values(arguments)){
    append(argv, a)
  }
  local r = os.exec(argv)
  local out = {status: r.status, events: {}, done: null, stdout: r.stdout}
  for(let local line in values(str.lines(r.stdout))){
    if(str.starts_with(line, "{")){
      local e = json.decode(line)
      if(e.event == "done"){
        out.done = e
      } else {
        out.events[str.join(e.path, " / ")] = e
      }
    }
  }
  return out
}

t.group("slang test"){
  t.teardown(func(){ os.remove_all(dir) })
  t.test("--json reports each test, --only picks some, failures exit 1"){
    write("demo_test.slang", {
      "local t = require(\"slang/test\")",
      "t.group(\"g\"){",
      "  t.test(\"ok\"){ assert(true) }",
      "  t.test(\"bad\"){ assert(1 == 2, \"one is not two\") }",
      "}",
    })
    local file = concat(dir, "/demo_test.slang")
    local r = run_json(file)
    assert(r.status == 1, r.stdout)
    assert(r.events["g / ok"].status == "passed", r.stdout)
    local bad = r.events["g / bad"]
    assert(bad.status == "failed" and bad.message == "one is not two", r.stdout)
    assert(bad.location.line == 4 and bad.file == file, r.stdout)
    assert(r.done.passed == 1 and r.done.failed == 1, r.stdout)
    r = run_json("--only", "g / ok", file)
    assert(r.status == 0 and r.done.passed == 1 and r.done.failed == 0, r.stdout)
    // an --only that matches nothing fails (a misspelled name)
    r = run_json("--only", "g / no such", file)
    assert(r.status == 1 and r.done.passed == 0, r.stdout)
  }
  t.test("a run goes on past a file that does not load, and failing setups"){
    write("a_test.slang", {
      "local t = require(\"slang/test\")",
      "t.group(\"a\"){",
      "  local n = 0",
      "  t.setup(func(){ n = n + 1; if(n == 2){ raise(\"setup broke\") } })",
      "  t.teardown(func(){ if(n == 3){ raise(\"teardown broke\") } })",
      "  t.test(\"one\"){ }",
      "  t.test(\"two\"){ }",
      "  t.test(\"three\"){ }",
      "  t.test(\"skipped\"){ t.skip(\"not here\") }",
      "}",
      "t.group(\"broken\"){",
      "  t.test(\"before\"){ }",
      "  raise(\"group broke\")",
      "}",
    })
    write("b_test.slang", {"local x = nothing.at_all"})
    write("c_test.slang", {
      "local t = require(\"slang/test\")",
      "t.test(\"in c\"){ }",
    })
    local r = run_json(dir)
    assert(r.status == 1, r.stdout)
    local e = r.events
    // the files run in order of their names, each one whatever came before
    assert(e["a / one"].status == "passed" and e["in c"].status == "passed", r.stdout)
    assert(e["a / two"].status == "failed" and
      str.contains(e["a / two"].message, "setup failed: setup broke"), r.stdout)
    assert(e["a / three"].status == "passed", r.stdout)
    assert(e["a / three (teardown)"].status == "failed", r.stdout)
    assert(e["a / skipped"].status == "skipped" and e["a / skipped"].message == "not here", r.stdout)
    assert(e["broken / before"].status == "passed", r.stdout)
    assert(e["broken / (the group's code)"].status == "failed", r.stdout)
    local loading = e[concat("(loading ", dir, "/b_test.slang)")]
    assert(loading != null and loading.status == "failed", r.stdout)
    assert(r.done.skipped == 1 and r.done.failed == 4, r.stdout)
  }
  t.test("the report shows the calls that led to a failure"){
    write("d_test.slang", {
      "local t = require(\"slang/test\")",
      "local func check(x){ assert(x == 2, \"not two\") }",
      "t.test(\"helper\"){ check(1) }",
    })
    local r = os.exec({slang, "test", concat(dir, "/d_test.slang")})
    assert(r.status == 1, r.stdout)
    // where it was raised, and the test's line that called the helper
    assert(str.contains(r.stdout, "d_test.slang:2:"), r.stdout)
    assert(str.contains(r.stdout, "d_test.slang:3:"), r.stdout)
  }
}
