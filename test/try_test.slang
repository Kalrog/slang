// try/catch with patterns, raising values, defer, if expressions
local t = require("slang/test")
local str = require("slang/string")

local func fails_to_compile(source, text){
  local r = pcall(compile, source, "src")
  assert(r[0] == "err", concat("should not compile: ", source))
  assert(str.index_of(r[1].message, text) >= 0, r[1].message)
}

t.group("raise"){
  t.test("a raised table comes back as it is, with where it was raised"){
    local raised = {kind: "not_found", path: "/x"}
    local r = pcall(func(){ raise(raised) })
    assert(r[1] == raised, "the same table")
    assert(r[1].kind == "not_found" and r[1].path == "/x")
    assert(r[1].location.line > 0 and type(r[1].stack) == "string")
  }
  t.test("a re-raise keeps the first location; strings still become error tables"){
    local first = null
    local r = pcall(func(){
      local inner = pcall(func(){ raise({kind: "deep"}) })
      first = inner[1].location.line
      raise(inner[1])
    })
    assert(r[1].kind == "deep" and r[1].location.line == first)
    local s = pcall(func(){ raise("plain") })
    assert(s[1].message == "plain")
    local e = pcall(func(){ error("built ", 42) })
    assert(e[1].message == "built 42")
  }
}

t.group("try and catch"){
  t.test("the first matching clause runs"){
    local log = {}
    local func risky(kind){
      if(kind == "nf"){ raise({kind: "not_found", path: "/x"}) }
      if(kind == "str"){ error("plain message") }
      return "fine"
    }
    for(let local k in values({"nf", "str", "ok"})){
      try {
        append(log, risky(k))
      } catch({kind: "not_found", path: local p}) {
        append(log, concat("missing ", p))
      } catch(local e) {
        append(log, concat("other: ", e.message))
      }
    }
    assert(log == {"missing /x", "other: plain message", "fine"}, concat("log ", log))
  }
  t.test("a value no clause matches is raised again, unchanged"){
    local raised = {kind: "boom"}
    local r = pcall(func(){
      try {
        raise(raised)
      } catch({kind: "other"}) {
        return "wrong"
      }
    })
    assert(r[0] == "err" and r[1] == raised)
  }
  t.test("catch without a pattern takes everything; catch(name) assigns"){
    local hit = false
    try { error("x") } catch { hit = true }
    assert(hit)
    local caught = null
    try { raise({n: 1}) } catch(caught) {}
    assert(caught.n == 1)
  }
  t.test("errors from called functions, deep frames and natives are caught"){
    local func deep(n){
      if(n == 0){ return to_int("not a number") }
      return deep(n - 1)
    }
    local msg = null
    try { deep(20) } catch(local e) { msg = e.message }
    assert(msg != null and str.index_of(msg, "not a number") >= 0, msg)
    local m2 = null
    try { local x = null; x.field = 1 } catch(local e) { m2 = e.message }
    assert(m2 != null)
  }
  t.test("return and break leave a try cleanly"){
    local func find(list, wanted){
      for(local i = 0; i < len(list); i = i + 1){
        try {
          if(list[i] == wanted){ return i }
        } catch { return -2 }
      }
      return -1
    }
    assert(find({"a", "b"}, "b") == 1 and find({}, "x") == -1)
    local count = 0
    for(local i = 0; i < 10; i = i + 1){
      try {
        if(i == 3){ break }
        count = count + 1
      } catch {}
    }
    assert(count == 3)
    // after leaving trys by return and break, an error is not caught by them
    local r = pcall(func(){ find({1}, 1) error("outside") })
    assert(r[0] == "err" and str.index_of(r[1].message, "outside") >= 0)
  }
  t.test("nested trys, raising from a catch, pcall inside and outside"){
    local log = {}
    try {
      try {
        raise({level: 1})
      } catch({level: 1}) {
        append(log, "inner")
        raise({level: 2})
      }
    } catch({level: 2}) {
      append(log, "outer")
    }
    assert(log == {"inner", "outer"})
    local r = pcall(func(){
      try { raise({a: 1}) } catch({a: 2}) {}
    })
    assert(r[1].a == 1)
    local caught = null
    try {
      local p = pcall(func(){ error("in pcall") })
      assert(p[0] == "err")
      raise({after: true})
    } catch(local e) { caught = e }
    assert(caught.after == true)
  }
  t.test("closures made inside a try keep their values after an error"){
    local saved = null
    try {
      local v = "captured"
      saved = func(){ return v }
      error("leave")
    } catch {}
    local other = "overwrite the slot"
    assert(saved() == "captured")
  }
  t.test("a try in a coroutine"){
    local thread = require("slang/thread")
    local got = null
    local co = thread.create(func(){
      try {
        thread.yield(1)
        error("after the yield")
      } catch(local e) {
        got = e.message
      }
      return "done"
    })
    assert(thread.resume(co) == 1)
    assert(thread.resume(co) == "done" and str.index_of(got, "after the yield") >= 0)
  }
}

t.group("defer"){
  t.test("deferred code runs when the block ends, last in first out"){
    local log = {};
    {
      defer append(log, "a")
      defer { append(log, "b") }
      append(log, "body")
    }
    append(log, "after")
    assert(log == {"body", "b", "a", "after"}, concat("log ", log))
  }
  t.test("a return keeps its value; the defers run before the function returns"){
    local log = {}
    local n = 1
    local func f(){
      defer { n = 99 append(log, "deferred") }
      return n + 1
    }
    assert(f() == 2 and n == 99 and log == {"deferred"})
  }
  t.test("in a loop, each iteration's defer runs at its end, and on break"){
    local log = {}
    for(local i = 0; i < 3; i = i + 1){
      defer append(log, concat("d", string(i)))
      if(i == 1){ break }
      append(log, concat("i", string(i)))
    }
    assert(log == {"i0", "d0", "d1"}, concat("log ", log))
  }
  t.test("errors pass through after the defers ran"){
    local log = {}
    local r = pcall(func(){
      defer append(log, "outer");
      {
        defer append(log, "inner")
        raise({kind: "boom"})
      }
    })
    assert(r[1].kind == "boom" and log == {"inner", "outer"}, concat("log ", log))
  }
  t.test("deferred code sees the names of its own place"){
    local x = "outer"
    local seen = null
    local func f(){
      defer { seen = x }
      {
        local x = "inner"
        return x
      }
    }
    assert(f() == "inner" and seen == "outer")
  }
  t.test("try inside defer, defer inside try, a loop inside defer"){
    local log = {}
    try {
      defer {
        try { error("in cleanup") } catch { append(log, "cleanup caught") }
        for(local i = 0; i < 5; i = i + 1){
          if(i == 2){ break }
          append(log, i)
        }
      }
      error("body")
    } catch(local e) {
      append(log, "caught body")
    }
    assert(log == {"cleanup caught", 0, 1, "caught body"}, concat("log ", log))
  }
  t.test("a defer may not return or break out of itself"){
    fails_to_compile("local func f(){ defer { return 1 } }", "return is not allowed inside defer")
    fails_to_compile("for(true){ defer { break } }", "break is not allowed to leave a defer")
  }
}

t.group("if expressions"){
  t.test("choose a value, with else if chains"){
    local func sign(n){
      return if(n < 0){ "negative" } else if(n == 0){ "zero" } else { "positive" }
    }
    assert(sign(-3) == "negative" and sign(0) == "zero" and sign(7) == "positive")
    assert(if(false){ 1 } else { 2 } + 10 == 12)
    local t = {v: if(true){ "yes" } else { "no" }}
    assert(t.v == "yes")
  }
  t.test("only the chosen branch is evaluated"){
    local calls = 0
    local func bump(){ calls = calls + 1 return calls }
    local v = if(true){ "a" } else { bump() }
    assert(v == "a" and calls == 0)
  }
  t.test("print back as written"){
    local ast = require("slang/ast")
    local compiler = require("slang/compiler")
    local src = "local v = if(a){ 1 } else if(b){ 2 } else { 3 }"
    assert(str.index_of(ast.to_source(compiler.parse(src, "p")), "if(a){ 1 } else if(b){ 2 } else { 3 }") >= 0)
  }
}
