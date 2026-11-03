local t = require("slang/test")
local compiler = require("slang/compiler")

local fixture = "test/fixtures/inline_tests.slang"

// slang test compiles the project's files with their tests: loading the
// fixture registers its groups and tests in this run
assert(compiler.testing, "slang test sets compiler.testing")
local m = compiler.load_file(fixture)()

t.group("inline tests: modes"){
  t.test("a test run registers the module's tests"){
    assert(INLINE_TEST_REGISTERED == 1, "registered once")
    assert(INLINE_TEARDOWNS == 2, "a teardown after the test and the subgroup")
    assert(m.double(2) == 4, "the module works")
  }
  t.test("any other compile leaves them out"){
    compiler.testing = false
    local r = pcall(func(){ return compiler.load_file(fixture)() })
    compiler.testing = true
    if(let {"err", local e} = r){
      raise(e)
    }
    assert(INLINE_TEST_REGISTERED == 1, "nothing registered")
    assert(INLINE_TEARDOWNS == 2, "no teardown ran")
    assert(r[1].double(3) == 6 and r[1].name == "a local named test", "the module")
  }
}
