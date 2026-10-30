// continue, and labeled break and continue
local t = require("slang/test")
local str = require("slang/string")

local func fails_to_compile(source, text){
  local r = pcall(compile, source, "src")
  assert(r[0] == "err", concat("should not compile: ", source))
  assert(str.index_of(r[1].message, text) >= 0, r[1].message)
}

t.group("continue"){
  t.test("skips to the next iteration in every kind of loop"){
    local out = {}
    for(local i = 0; i < 6; i = i + 1){
      if(i % 2 == 0){ continue }
      append(out, i)
    }
    assert(out == {1, 3, 5}, concat("for: ", out))
    out = {}
    for(let local x in values({1, 2, 3, 4})){
      if(x == 2){ continue }
      append(out, x)
    }
    assert(out == {1, 3, 4}, concat("for-in: ", out))
    out = {}
    local n = 0
    for(n < 5){
      n = n + 1
      if(n == 3){ continue }
      append(out, n)
    }
    assert(out == {1, 2, 4, 5}, concat("for(condition): ", out))
  }
  t.test("each iteration's closures keep their own values"){
    local fs = {}
    for(local i = 0; i < 3; i = i + 1){
      local x = i * 10
      fs[i] = func(){ return x }
      if(i < 5){ continue }
    }
    assert(fs[0]() == 0 and fs[1]() == 10 and fs[2]() == 20)
  }
  t.test("defers run and trys end on the way out"){
    local out = {}
    for(local i = 0; i < 3; i = i + 1){
      defer append(out, concat("d", string(i)))
      if(i == 1){ continue }
      append(out, concat("i", string(i)))
    }
    assert(out == {"i0", "d0", "d1", "i2", "d2"}, concat("out ", out))
    for(local i = 0; i < 3; i = i + 1){
      try {
        if(i < 3){ continue }
      } catch { }
    }
    // no try is left behind to catch this
    local r = pcall(func(){ error("after the loop") })
    assert(r[0] == "err")
    local caught = false
    local r2 = pcall(func(){
      for(local i = 0; i < 2; i = i + 1){
        try {
          continue
        } catch {
          caught = true
        }
      }
      error("outside")
    })
    assert(r2[0] == "err" and not caught)
  }
  t.test("continue outside a loop does not compile"){
    fails_to_compile("local x = 1\ncontinue", "continue outside of a loop")
  }
}

t.group("labels"){
  t.test("break and continue reach the labeled loop"){
    local out = {}
    :rows: for(local r = 0; r < 3; r = r + 1){
      for(local c = 0; c < 3; c = c + 1){
        if(c == 1){ continue rows }
        if(r == 2){ break rows }
        append(out, concat(string(r), string(c)))
      }
    }
    assert(out == {"00", "10"}, concat("out ", out))
    local found = null
    :search: for(let local row in values({{1, 2}, {3, 4}, {5, 6}})){
      for(let local v in values(row)){
        if(v == 4){
          found = row
          break search
        }
      }
    }
    assert(found[0] == 3)
  }
  t.test("an unlabeled break or continue is the innermost loop's"){
    local out = {}
    :outer: for(local i = 0; i < 2; i = i + 1){
      for(local j = 0; j < 3; j = j + 1){
        if(j == 1){ break }
        append(out, concat(string(i), string(j)))
      }
    }
    assert(out == {"00", "10"})
  }
  t.test("labels print back"){
    local ast = require("slang/ast")
    local compiler = require("slang/compiler")
    local src = ":outer: for(let local x in xs){\n  continue outer\n}"
    local printed = ast.to_source(compiler.parse(src, "p"))
    assert(
      str.index_of(printed, ":outer: for(let local x in xs)") >= 0 and
        str.index_of(printed, "continue outer") >= 0,
      printed
    )
  }
  t.test("a label must name an enclosing loop; a defer may not be left"){
    fails_to_compile(
      "for(true){ break nowhere }",
      "no enclosing loop is labeled nowhere"
    )
    fails_to_compile(
      ":a: for(true){ }\nfor(true){ continue a }",
      "no enclosing loop is labeled a"
    )
    fails_to_compile(
      ":a: for(true){ defer { break a } }",
      "break is not allowed to leave a defer"
    )
  }
}

t.group("break out of a for-in"){
  t.test("lands on the pop of the iterator (nothing is left on the stack)"){
    local vm = require("slang/vm")
    local func f(){
      for(let local x in values({1, 2})){ break }
    }
    local text = vm.disassemble(f)
    local lines = str.split(text, "\n")
    local target = null
    for(let local line in values(lines)){
      // the break: a forward jump with the break's location (line 1 of f's body)
      if(str.index_of(line, "jump") >= 0 and
        str.index_of(line, "continue_test.slang") >= 0 and target == null){
        local arrow = str.index_of(line, "-> ")
        if(arrow >= 0){
          target = to_int(str.trim(str.substring(line, arrow + 3, arrow + 8)))
        }
      }
    }
    assert(target != null, text)
    local landing = null
    for(let local line in values(lines)){
      if(str.starts_with(str.trim(line), concat(string(target), ":"))){
        landing = line
      }
    }
    assert(
      landing != null and str.index_of(landing, "pop") >= 0,
      concat("lands on: ", string(landing))
    )
  }
}
