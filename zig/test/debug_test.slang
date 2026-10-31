// the debugger: slang run --debug, driven over the Debug Adapter Protocol
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local json = require("slang/json")
local uv = require("uv")
local async = require("slang/async")

local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/",
  "/slang-debug-test-",
  string(uv.getpid()),
)
os.mkdir_all(scratch)

local program = str.join({
  "local func add(a, b){",
  "  local sum = a + b",
  "  return sum",
  "}",
  "local total = 0",
  "for(local i = 0; i < 3; i = i + 1){",
  "  total = add(total, i)",
  "}",
  "print(\"total \", total, \"\\n\")",
  "",
}, "\n")

// a protocol client on a stream and a connection
local func client(conn){
  local stream = async.reader(conn)
  local c = {seq: 0, buffer: ""}
  // the next message, or null when the connection ended
  func c.receive(){
    for(true){
      local head = str.index_of(c.buffer, "\r\n\r\n")
      if(head >= 0){
        local length = to_int(str.trim(str.substring(c.buffer, 15, head)))
        if(len(c.buffer) >= head + 4 + length){
          local body = str.substring(c.buffer, head + 4, head + 4 + length)
          c.buffer = str.substring(c.buffer, head + 4 + length)
          return json.decode(body, "message")
        }
      }
      local chunk = async.await(stream:next())
      if(chunk.done){
        return null
      }
      c.buffer = concat(c.buffer, chunk.value)
    }
  }
  func c.until(test){
    for(true){
      local m = c.receive()
      if(m == null or test(m)){
        return m
      }
    }
  }
  func c.request(command, arguments){
    c.seq = c.seq + 1
    local seq = c.seq
    local body = json.encode({
      seq: seq,
      type: "request",
      command: command,
      arguments: arguments or {},
    })
    async.await(async.write(conn, concat(
      "Content-Length: ", string(len(body)), "\r\n\r\n", body
    )))
    return c.until(func(m){
      return m.type == "response" and m.request_seq == seq
    })
  }
  func c.event(name){
    return c.until(func(m){ return m.type == "event" and m.event == name })
  }
  return c
}

t.group("debugger"){
  t.test("a conditional breakpoint, the stack, locals, evaluate, continue"){
    local source = concat(scratch, "/prog.slang")
    os.write_file(source, program)
    local port = 40000 + uv.getpid() % 20000
    local r = async.main(func(){
      local p = async.spawn(os.executable(), {
        "run",
        "--debug",
        string(port),
        source,
      }, {stdio: {"pipe", "pipe", "pipe"}})
      // it says when it listens
      local err = async.reader(p.stderr)
      local said = ""
      for(str.index_of(said, "waiting for a debugger") < 0){
        local chunk = async.await(err:next())
        assert(not chunk.done, concat("no debugger port: ", said))
        said = concat(said, chunk.value)
      }
      local out = async.reader(p.stdout)
      local c = client(async.await(async.connect("127.0.0.1", port)))
      assert(c.request("initialize", {adapterID: "slang"}).success)
      c.request("launch", {})
      local bp = c.request("setBreakpoints", {
        source: {path: source},
        breakpoints: {{line: 2, condition: "a == 1"}},
      })
      assert(bp.body.breakpoints[0].verified)
      c.request("configurationDone")
      local stopped = c.event("stopped")
      local frames = c.request("stackTrace", {threadId: 1}).body.stackFrames
      local scopes = c.request("scopes", {frameId: frames[0].id}).body.scopes
      local vars = c.request("variables", {
        variablesReference: scopes[0].variablesReference,
      }).body.variables
      local seen = {}
      for(let local v in values(vars)){
        seen[v.name] = v.value
      }
      local value = c.request("evaluate", {
        expression: "a + b * 10",
        frameId: frames[0].id,
      }).body.result
      c.request("continue", {threadId: 1})
      local exited = c.event("exited")
      local printed = ""
      for(true){
        local chunk = async.await(out:next())
        if(chunk.done){
          break
        }
        printed = concat(printed, chunk.value)
      }
      return {
        reason: stopped.body.reason,
        top: frames[0].name,
        line: frames[0].line,
        caller: frames[1].line,
        a: seen.a,
        b: seen.b,
        value: value,
        code: exited.body.exitCode,
        printed: printed,
      }
    })
    assert(
      r.reason == "breakpoint" and r.top == "add" and r.line == 2,
      string(r),
    )
    assert(r.caller == 7, string(r))
    assert(r.a == "1" and r.b == "2", string(r))
    assert(r.value == "21", string(r))
    assert(r.code == 0 and r.printed == "total 3\n", string(r))
  }
}
