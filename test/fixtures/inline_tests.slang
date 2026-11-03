// a module with its tests inline (test/inline_test_test.slang loads it)
extension "extensions/inline_test"

local m = {}

func m.double(x){
  return x * 2
}

// group and test stay usable as names
local test = "a local named test"
m.name = test

group("inline tests"){
  // counts the registrations: a compile without tests has none
  INLINE_TEST_REGISTERED = (INLINE_TEST_REGISTERED or 0) + 1
  local helper = 21
  // before each test and subgroup of this group, and after each
  local setups = 0
  setup{
    setups = setups + 1
  }
  teardown{
    INLINE_TEARDOWNS = (INLINE_TEARDOWNS or 0) + 1
  }
  test("see the module's locals"){
    assert(m.double(helper) == 42, "double(21)")
    assert(setups == 1, "the setup ran before")
  }
  group("nested"){
    test("runs too"){
      assert(test == "a local named test", "the local")
      assert(setups == 2, "the setup ran before the subgroup")
    }
  }
}

test("at the top of the module"){
  assert(m.name == "a local named test", "m.name")
}

return m
