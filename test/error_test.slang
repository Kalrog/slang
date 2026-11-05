// the error library (error.new, wrap, is, message), errors' metatable,
// try expressions and t.raises
local t = require("slang/test")

// whether part is in s
local func str_has(s, part){
  return require("slang/string").index_of(s, part) >= 0
}

t.group("errors"){
  t.test("raise of a string gives an error of kind error; errors share a metatable"){
    local e = t.raises(func(){ raise("boom 42") }, "boom 42")
    assert(e.@meta == error.meta and e.message == "boom 42")
    assert(e.location.line > 0)
    local raised = {kind: "mine"}
    local r = t.raises(func(){ raise(raised) }, "mine")
    assert(r == raised and r.@meta == error.meta, "a raised table gets the metatable")
    local own = {@meta: {__type: "Custom"}}
    assert(type(t.raises(func(){ raise(own) })) == "Custom", "its own metatable stays")
  }
  t.test("new builds an error without raising it"){
    local e = error.new("not_found", "no user 7", {id: 7})
    assert(e.@meta == error.meta and e.kind == "not_found" and e.id == 7)
    assert(e.location == null, "not raised yet")
    local caught = try { raise(e) } catch({kind: "not_found", id: local id}) { id }
    assert(caught == 7)
  }
  t.test("wrap keeps the kind and the cause; message follows the causes"){
    local inner = error.new("not_found", "cannot read /x")
    local outer = error.wrap(inner, "loading the config")
    assert(outer.kind == "not_found" and outer.cause == inner)
    assert(error.message(outer) == "loading the config: cannot read /x")
    assert(string(outer) == "loading the config: cannot read /x", "__tostring")
    assert(error.wrap(inner, "other", {kind: "config"}).kind == "config")
    assert(error.wrap("plain", "context").kind == "error")
    assert(error.message(error.wrap("plain", "context")) == "context: plain")
  }
  t.test("is looks through causes"){
    local e = error.wrap(error.new("timeout", "slow"), "fetching")
    assert(error.is(e, "timeout") and not error.is(e, "closed"))
    assert(not error.is("text", "timeout") and not error.is(null, "x"))
  }
}

t.group("kinds"){
  t.test("the VM's errors"){
    local tb = {}
    assert(t.raises(func(){ return 1 + tb }).kind == "type")
    assert(t.raises(func(){ local n = null  return n.x }).kind == "type")
    assert(t.raises(func(){ local n = 5  n() }).kind == "type")
    assert(t.raises(func(){ return 5 % 0 }).kind == "arithmetic")
    assert(t.raises(func(){ raise("plain") }).kind == "error")
    assert(t.raises(func(){ error("not callable") }).kind == "type", "error is a table")
    local func deep(){ return deep() + 1 }
    assert(t.raises(deep).kind == "stack_overflow")
  }
  t.test("natives: arguments, formats, the operating system"){
    local str = require("slang/string")
    assert(t.raises(func(){ str.substring("abc", 9) }).kind == "argument")
    assert(t.raises(func(){ to_int({}) }).kind == "argument")
    assert(t.raises(func(){ require("slang/regex").compile("(") }).kind == "format")
    assert(t.raises(func(){ str.format("%") }).kind == "format")
    local os = require("slang/os")
    local e = t.raises(func(){ os.read_file("/no/such/file") }, "not_found")
    assert(e.path == "/no/such/file" and e.code == "FileNotFound", string(e.code))
    assert(t.raises(func(){ os.list_dir("/no/such/dir") }).kind == "not_found")
  }
  t.test("to_int and to_float give null for what is not a number"){
    assert(to_int("12x") == null and to_float("x") == null)
    assert(to_int(" 7") == null and to_int("0x1f") == 31 and to_float("2.5") == 2.5)
  }
  t.test("lists take null with table.insert"){
    local list = {1, 3}
    require("slang/table").insert(list, 1, null)
    assert(len(list) == 3 and list[1] == null and list[2] == 3)
  }
}

t.group("error.kinds"){
  t.test("names the kinds; a misspelt one raises"){
    assert(error.kinds.not_found == "not_found" and error.kinds["for"] == "for")
    local e = t.raises(func(){ return error.kinds.not_fuond }, "argument")
    assert(str_has(e.message, "not_fuond"))
  }
  t.test("every kind the VM raises is listed"){
    local tb = {}
    local raised = {
      t.raises(func(){ return 1 + tb }),
      t.raises(func(){ return 5 % 0 }),
      t.raises(func(){ to_int({}) }),
      t.raises(func(){ require("slang/regex").compile("(") }),
      t.raises(func(){ require("slang/os").read_file("/no/such/file") }),
      t.raises(func(){ assert(false) }),
      t.raises(func(){ raise("x") }),
      t.raises(func(){ compile("local x = (", "src") }),
      t.raises(func(){ compile("break", "src") }),
      t.raises(func(){ let {a: 1} = {a: 2} }),
    }
    for(let local e in values(raised)){
      assert(error.kinds[e.kind] == e.kind, e.kind)
    }
  }
}

t.group("pinned patterns"){
  t.test("^ compares instead of binding"){
    local wanted = "admin"
    assert(let {role: ^wanted} = {role: "admin"})
    assert(not (let {role: ^wanted} = {role: "guest"}))
    local name = "unchanged"
    assert(let {role: name} = {role: "guest"})
    assert(name == "guest", "a bare name binds")
    assert(let {n: ^(1 + 2)} = {n: 3})
  }
  t.test("in catch, with error.kinds"){
    local func load(){ raise(error.new(error.kinds.not_found, "gone", {path: "/x"})) }
    local got = try { load() } catch({kind: ^error.kinds.permission}) { "no" }
      catch({kind: ^error.kinds.not_found, path: local p}) { p }
    assert(got == "/x")
  }
  t.test("in for-in"){
    local seen = {}
    local open = "open"
    for(let? {state: ^open, id: local id} in values({{state: "open", id: 1}, {state: "shut", id: 2}})){
      append(seen, id)
    }
    assert(seen == {1})
  }
  t.test("print back with ^"){
    local ast = require("slang/ast")
    local compiler = require("slang/compiler")
    local src = "let {kind: ^error.kinds.io, n: ^(a + 1), m: 2, x: local x} = v\n"
    local text = ast.to_source(compiler.parse(src))
    assert(text == src, text)
  }
}

t.group("raw_type"){
  t.test("ignores __type"){
    local p = {@meta: {__type: "Point"}}
    assert(type(p) == "Point" and raw_type(p) == "table")
    assert(raw_type(1) == "int" and raw_type(1.5) == "double" and raw_type("s") == "string")
    assert(raw_type(null) == "null" and raw_type(print) == "function" and raw_type(true) == "bool")
    assert(raw_type(stop) == "userdata" and type(stop) == "stop")
  }
}

t.group("try expressions"){
  t.test("the value, or the matching clause's"){
    local func parse(s){
      if(s == "bad"){ raise(error.new("format", "bad input")) }
      return s
    }
    assert(try { parse("ok") } catch { "fallback" } == "ok")
    assert(try { parse("bad") } catch { "fallback" } == "fallback")
    local v = try { parse("bad") } catch({kind: "timeout"}) { 1 } catch({kind: "format"}) { 2 }
    assert(v == 2)
    local m = try { parse("bad") } catch(local e) { e.message }
    assert(m == "bad input")
  }
  t.test("no clause matching raises again"){
    local e = t.raises(func(){
      return try { raise({kind: "a"}) } catch({kind: "b"}) { 0 }
    }, "a")
    assert(e.kind == "a")
  }
  t.test("inside other expressions, with temporaries on the stack"){
    local func f(a, b, c){ return concat(string(a), string(b), string(c)) }
    assert(f(1, try { raise("x") } catch(local e) { e.message }, 3) == "1x3")
    local total = 10 + try { to_int("x") + 1 } catch { 5 } * 2
    assert(total == 20, string(total))
    local list = {try { 1 } catch { 0 }, try { raise("y") } catch { 2 }}
    assert(list == {1, 2})
  }
  t.test("closures made in a clause keep its values"){
    local fs = {}
    for(local i = 0; i < 3; i = i + 1){
      append(fs, try { raise(string(i)) } catch(local e) { func(){ return e.message } })
    }
    local other = "reuse the registers"
    assert(fs[0]() == "0" and fs[2]() == "2")
  }
  t.test("prints back as written"){
    local ast = require("slang/ast")
    local compiler = require("slang/compiler")
    local node = compiler.parse("local v = try { f() } catch(local e) { g(e) } catch { 0 }")
    local text = ast.to_source(node)
    assert(text == "local v = try { f() } catch(local e) { g(e) } catch { 0 }\n", text)
  }
}

t.group("raises"){
  t.test("returns the error, checks kind or message"){
    local e = t.raises(func(){ raise(error.new("closed", "the channel is closed")) }, "closed")
    assert(e.kind == "closed")
    t.raises(func(){ raise("a long message") }, "long")
    local returned = try { t.raises(func(){ return 1 }) } catch(local e) { e.message }
    assert(returned == "expected an error, but the function returned", returned)
    local wrong = try { t.raises(func(){ raise("x") }, "y") } catch(local e) { e.message }
    assert(wrong == "expected an error with y, got: x", wrong)
  }
}
