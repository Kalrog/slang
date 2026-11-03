// the sampling profiler: slang run --profile out.folded
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local uv = require("uv")
local async = require("slang/async")

local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/",
  "/slang-profile-test-",
  string(uv.getpid()),
)
os.mkdir_all(scratch)

local program = """
local func hot(n){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + i % 7 }
  return s
}
local func cold(){ return 1 }
local m = {}
func m.run(){
  local x = 0
  for(local k = 0; k < 40; k = k + 1){
    x = x + hot(20000) + cold()
  }
  return x
}
m.run()
"""

t.group("profiler"){
  t.test("samples are named by function and attributed to the hot one"){
    local source = concat(scratch, "/hot.slang")
    local folded = concat(scratch, "/hot.folded")
    os.write_file(source, program)
    local r = async.main(func(){
      return async.await(async.exec("bin/slang", {
        "run", "--profile", folded, source
      }))
    })
    assert(r.status == 0, concat("exit ", r.status, ": ", r.stderr))
    assert(str.index_of(r.stderr, "self ms") >= 0, r.stderr)
    local lines = str.split(os.read_file(folded), "\n")
    local hot = 0
    local all = 0
    for(let local line in values(lines)){
      if(len(line) > 0){
        local cut = len(line) - 1
        for(str.char_at(line, cut) != " "){
          cut = cut - 1
        }
        local us = to_int(str.substring(line, cut + 1))
        local stack = str.substring(line, 0, cut)
        all = all + us
        // hot on top, called from m.run
        if(str.index_of(stack, "m.run (") >= 0 and
          str.ends_with(stack, concat("hot (", source, ":3)"))){
          hot = hot + us
        }
      }
    }
    assert(all > 0, "something was sampled")
    assert(
      hot * 2 > all,
      concat("hot has most of the time: ", hot, " of ", all),
    )
  }
  t.test("a program that ends with os.exit still writes its profile"){
    local source = concat(scratch, "/exit.slang")
    local folded = concat(scratch, "/exit.folded")
    os.write_file(source, concat(program, "require(\"slang/os\").exit(3)\n"))
    local r = async.main(func(){
      return async.await(async.exec("bin/slang", {
        "run", "--profile", folded, source
      }))
    })
    assert(r.status == 3, concat("exit ", r.status, ": ", r.stderr))
    assert(os.exists(folded), "the profile was written")
    assert(str.index_of(os.read_file(folded), "hot (") >= 0, "with samples")
  }
}
