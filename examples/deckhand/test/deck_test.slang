// the deck: sandboxed scripts, wait, the tick guard, errors
local t = require("slang/test")
local deck = require("game/deck")

// a network with one door that records what was done to it
local func network(){
  local door = {kind: "door", help: "open(s), close()", calls: {}}
  door.open = func(s){ append(door.calls, {"open", s}) }
  door.close = func(){ append(door.calls, {"close"}) }
  return {names: {"door1"}, objects: {door1: door}, door: door}
}

local func last(d){
  return d.log[len(d.log) - 1]
}

t.group("deck"){
  t.test("a script calls the objects of its network"){
    local d = deck.new()
    local n = network()
    assert(d:run("door1.open(3)", n))
    assert(n.door.calls[0][0] == "open" and n.door.calls[0][1] == 3)
    assert(d:running() == 0)
  }
  t.test("only the network and the builtins are visible"){
    local d = deck.new()
    d:run("require(\"slang/os\")", network())
    assert(last(d).kind == "err", last(d).text)
    d:run("print(door2)", network())
    assert(last(d).text == "null")
  }
  t.test("wait suspends until the clock has moved on"){
    local d = deck.new()
    local n = network()
    d:run("door1.open(1)\nwait(2)\ndoor1.close()", n)
    assert(len(n.door.calls) == 1 and d:running() == 1)
    d:update(1.0)
    assert(len(n.door.calls) == 1)
    d:update(2.0)
    assert(len(n.door.calls) == 2 and n.door.calls[1][0] == "close")
    assert(d:running() == 0)
  }
  t.test("an endless loop is sliced, not hung"){
    local d = deck.new()
    d:run("local n = 0\nfor(true){ n = n + 1 }", network())
    assert(d:running() == 1)
    d:update(0.1)
    assert(d:running() == 1)
    d:stop_all()
    assert(d:running() == 0)
  }
  t.test("endless recursion is sliced too"){
    local d = deck.new()
    d:run(
      "local f = func(){ return 1 }\nfor(local i = 0; true; i = i + 1){ f() }",
      network(),
    )
    assert(d:running() == 1)
    d:stop_all()
  }
  t.test("the tick cannot be named or replaced"){
    local d = deck.new()
    d:run("tick = null\nfor(true){}", network())
    assert(d:running() == 1)
    d:stop_all()
  }
  t.test("a lone expression or call shows its value"){
    local d = deck.new()
    d:run("1 + 2", network())
    assert(last(d).text == "3", last(d).text)
    d:run("7 / 2", network())
    assert(last(d).text == "3.5", last(d).text)
    d:run("{1, 2}", network())
    assert(last(d).text == "{1, 2}", last(d).text)
  }
  t.test("syntax errors are short"){
    local d = deck.new()
    assert(not d:run("door1.open(3", network()))
    assert(last(d).kind == "err")
    assert(last(d).text == "syntax error at 1:13", last(d).text)
  }
  t.test("run time errors name the line"){
    local d = deck.new()
    d:run("wait(1)\ndoor1.jump()", network())
    d:update(1.0)
    assert(last(d).kind == "err")
    assert(
      require("slang/string").ends_with(last(d).text, "(line 2)"),
      last(d).text,
    )
  }
  t.test("stop() inside a script ends every script"){
    local d = deck.new()
    d:run("for(true){ wait(1) }", network())
    d:run("wait(0.5)\nstop()", network())
    assert(d:running() == 2)
    d:update(0.5)
    assert(d:running() == 0)
  }
  t.test("unquotes are refused"){
    local d = deck.new()
    assert(not d:run("-{block: print(1)}", network()))
  }
}
