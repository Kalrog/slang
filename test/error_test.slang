// the error library (error.new, wrap, is, message), errors' metatable,
// try expressions and t.raises
local t = require("slang/test")

t.group("errors"){
  t.test("error() still raises; errors share a metatable"){
    local e = t.raises(func(){ error("boom ", 42) }, "boom 42")
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
    assert(f(1, try { error("x") } catch(local e) { e.message }, 3) == "1x3")
    local total = 10 + try { to_int("x") + 1 } catch { 5 } * 2
    assert(total == 20, string(total))
    local list = {try { 1 } catch { 0 }, try { error("y") } catch { 2 }}
    assert(list == {1, 2})
  }
  t.test("closures made in a clause keep its values"){
    local fs = {}
    for(local i = 0; i < 3; i = i + 1){
      append(fs, try { error(string(i)) } catch(local e) { func(){ return e.message } })
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
    t.raises(func(){ error("a long message") }, "long")
    local returned = try { t.raises(func(){ return 1 }) } catch(local e) { e.message }
    assert(returned == "expected an error, but the function returned", returned)
    local wrong = try { t.raises(func(){ error("x") }, "y") } catch(local e) { e.message }
    assert(wrong == "expected an error with y, got: x", wrong)
  }
}
