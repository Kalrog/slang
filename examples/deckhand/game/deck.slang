// game/deck: the deck's scripts. What the player types is slang, compiled
// in a sandbox whose globals are the objects on a port's network plus a few
// builtins (print, wait, help, ...).
//
//   local d = deck.new()
//   d:run("door1.open(3); wait(1); cam1.off(2)", {door1: ..., cam1: ...})
//   d:update(now)      // every frame, with the world's time
//
// compile(code, origin, env) sandboxes names but not time, so two things
// are added here:
//   - every loop body and function body starts with a call to `tick!` (a
//     name no program can write); the tick counts steps and yields the
//     script when its slice of the frame is used up, so `for(true){}` costs
//     a frame budget instead of hanging the game
//   - every script is a coroutine, and wait(s) yields it until the deck's
//     clock has moved s seconds on
local thread = require("slang/thread")
local vm = require("slang/vm")
local compiler = require("slang/compiler")
local str = require("slang/string")
local math = require("slang/math")

local deck = {}

local TICK = "tick!"
// steps a script may take per frame before it is suspended until the next
deck.SLICE = 4000
// scripts one deck may run at once
deck.MAX_SCRIPTS = 8
// lines kept in the log
deck.LOG_LINES = 200

// ------------------------------------------------------------ the guard

local func tick_statement(){
  return {
    type: "CallStat",
    call: {type: "Call", function: {type: "Identifier", value: TICK}, args: {}},
  }
}

local primitive = {
  null: true, bool: true, int: true, double: true, string: true, function: true
}

// AST nodes are tables whose type() is their node type (`'For{...}`)
local func is_table(v){
  return primitive[type(v)] == null
}

// guard(node) -> node, with a tick at the start of every loop and function
// body (the tree is changed in place)
func deck.guard(node){
  if(not is_table(node)){
    return node
  }
  for(let local e in entries(node)){
    // tokens repeat parts of the tree; they are not compiled
    if(e[0] != "token" and is_table(e[1])){
      deck.guard(e[1])
    }
  }
  local t = node.type
  if((t == "For" or t == "ForIn" or t == "Function") and node.body != null and
    node.body.type == "Block"){
    node.body.statements = {tick_statement(), ...node.body.statements}
  }
  return node
}

// ------------------------------------------------------------ compiling

// "Failed to parse source: ...:deck:1:1 (farthest: "_" expected at 1:13)"
// -> "syntax error at 1:13"
local func short_parse_error(message){
  local at = str.index_of(message, "expected at ")
  if(at != null and at >= 0){
    local pos = str.substring(message, at + 12)
    local close = str.index_of(pos, ")")
    if(close != null and close >= 0){
      pos = str.substring(pos, 0, close)
    }
    return concat("syntax error at ", pos)
  }
  return message
}

local func parse(code, origin){
  return compiler.grammar():parse_source(code, origin, {sandbox: true})
}

// compile(code, env) -> {fn} or {error: message}. A lone expression or call
// is returned, so its value can be shown (as in a REPL).
func deck.compile(code, env, origin){
  origin = origin or "deck"
  local node
  local r = pcall(parse, code, origin)
  if(r[0] == "ok"){
    node = r[1]
    local stats = node.statements
    if(len(stats) == 1 and stats[0].type == "CallStat"){
      node.statements = {{type: "Return", value: stats[0].call}}
    }
  } else {
    // not statements: maybe an expression (`door1.is_open()` parses either
    // way, `1 + 2` only this way)
    local r2 = pcall(parse, concat("return ", code), origin)
    if(r2[0] != "ok"){
      return {error: short_parse_error(r[1].message)}
    }
    node = r2[1]
  }
  deck.guard(node)
  local c = pcall(compile, node, origin, env)
  if(c[0] != "ok"){
    return {error: c[1].message}
  }
  return {fn: c[1]}
}

// ------------------------------------------------------------ values

// show(v) -> how the deck prints a value
func deck.show(v){
  local t = type(v)
  if(t == "string"){
    return v
  }
  if(t == "double"){
    if(v == math.floor(v) and math.abs(v) < 1e15){
      return string(to_int(v))
    }
    return string(math.round(v * 1000) / 1000)
  }
  if(t == "table"){
    if(v.@meta != null and v.@meta.__tostring != null){
      return string(v)
    }
    local parts = {}
    local n = 0
    for(let local e in entries(v)){
      if(n >= 8){
        append(parts, "...")
        break
      }
      if(type(e[0]) == "int"){
        append(parts, deck.show(e[1]))
      } else {
        append(parts, concat(deck.show(e[0]), ": ", deck.show(e[1])))
      }
      n = n + 1
    }
    return concat("{", str.join(parts, ", "), "}")
  }
  if(t == "function"){
    return "<function>"
  }
  return string(v)
}

// n: how many arguments print was given (vm.arg_count: a null one is a
// gap in args, a trailing one is not there at all)
local func line_of(args, n){
  local parts = {}
  for(local i = 0; i < n; i = i + 1){
    append(parts, deck.show(args[i]))
  }
  return str.join(parts, " ")
}

// where(e) -> " (line n)" for an error raised by deck code, else ""
local func where(e){
  if(e.location != null and e.location.origin == "deck"){
    return concat(" (line ", e.location.line, ")")
  }
  return ""
}

// ------------------------------------------------------------ the deck

local Deck = {}
// the metatable of every deck (not Deck.@meta: that would be Deck's own)
local deck_meta = {__index: Deck}

// new() -> a deck: a clock, a log and the scripts it is running
func deck.new(){
  return {
    now: 0.0, log: {}, scripts: {}, next_id: 1, steps: 0, generation: 0,
    @meta: deck_meta
  }
}

// out(text, kind): a line in the log; kind is "out", "in", "err" or "sys"
func Deck.out(self, text, kind){
  for(let local line in values(str.split(text, "\n"))){
    append(self.log, {text: line, kind: kind or "out"})
  }
  for(len(self.log) > deck.LOG_LINES){
    remove(self.log, 0)
  }
}

// builtins(script) -> the functions every script sees
func Deck.builtins(self, network){
  local d = self
  local env = {}
  env[TICK] = func(){
    d.steps = d.steps + 1
    if(d.steps > deck.SLICE){
      thread.yield({slice: true})
    }
  }
  env.print = func(...args){
    d:out(line_of(args, vm.arg_count()), "out")
  }
  env.wait = func(seconds){
    if(type(seconds) != "int" and type(seconds) != "double"){
      error("wait(seconds) needs a number")
    }
    if(seconds < 0){
      error("wait(seconds) cannot go back in time")
    }
    thread.yield({until: d.now + seconds})
  }
  env.time = func() => d.now
  env.help = func(){
    local names = {}
    for(let local name in values(network.names)){
      local o = network.objects[name]
      append(names, concat(name, " (", o.kind, "): ", o.help))
    }
    d:out(str.join(names, "\n"), "sys")
    d:out(
      "wait(s), print(...), time(), stop(), help(); slang: for, if, func, ...",
      "sys",
    )
  }
  env.stop = func(){
    d:stop_all()
  }
  env.len = len
  env.string = string
  env.to_int = to_int
  env.type = type
  env.append = append
  env.remove = remove
  env.keys = keys
  env.values = values
  env.entries = entries
  env.concat = concat
  env.math = {
    pi: math.pi, floor: math.floor, ceil: math.ceil, round: math.round,
    abs: math.abs, min: math.min, max: math.max, random: math.random,
    sqrt: math.sqrt, sin: math.sin, cos: math.cos
  }
  for(let local name in values(network.names)){
    env[name] = network.objects[name]
  }
  return env
}

// run(code, network) -> true if a script started. network is {names:
// {name}, objects: {name: object}}; objects are what the script sees.
func Deck.run(self, code, network){
  self:out(code, "in")
  if(str.trim(code) == ""){
    return false
  }
  if(len(self.scripts) >= deck.MAX_SCRIPTS){
    self:out(
      concat(
        "deck busy: ", len(self.scripts), " scripts running (stop() ends them)"
      ),
      "err",
    )
    return false
  }
  local c = deck.compile(code, self:builtins(network))
  if(c.error != null){
    self:out(c.error, "err")
    return false
  }
  local id = self.next_id
  self.next_id = id + 1
  append(self.scripts, {
    id: id, co: thread.create(c.fn), wake: self.now, started: false
  })
  // run at once, up to its first wait
  self:step()
  return true
}

// step(): resumes every script whose time has come
func Deck.step(self){
  local i = 0
  for(i < len(self.scripts)){
    local s = self.scripts[i]
    local finished = false
    if(s.wake <= self.now + 0.000001){
      self.steps = 0
      local generation = self.generation
      local r = pcall(thread.resume, s.co)
      if(self.generation != generation){
        // the script called stop(): the list it was in is gone
        return
      }
      if(r[0] != "ok"){
        self:out(concat("error: ", r[1].message, where(r[1])), "err")
        finished = true
      } else if(thread.state(s.co) == "dead"){
        if(r[1] != null){
          self:out(deck.show(r[1]), "out")
        }
        finished = true
      } else if(type(r[1]) == "table" and r[1].until != null){
        s.wake = r[1].until
      } else {
        // a used up slice or a bare yield: again next frame
        s.wake = self.now
      }
    }
    if(finished){
      remove(self.scripts, i)
    } else {
      i = i + 1
    }
  }
}

// update(now): the clock moves to now and due scripts run
func Deck.update(self, now){
  self.now = now
  self:step()
}

// stop_all(): ends every running script
func Deck.stop_all(self){
  local n = len(self.scripts)
  self.scripts = {}
  self.generation = self.generation + 1
  if(n == 1){
    self:out("stopped 1 script", "sys")
  } else if(n > 1){
    self:out(concat("stopped ", n, " scripts"), "sys")
  }
}

// running() -> how many scripts are running
func Deck.running(self){
  return len(self.scripts)
}

return deck
