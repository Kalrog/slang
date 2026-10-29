// slang/webview: real windows (macOS), so not part of `make test`; run with
// `make test-gui`. Each test opens small windows and closes them itself.
extension "extensions/async"
local t = require("slang/test")
local str = require("slang/string")
local webview = require("slang/webview")
local web = require("slang/web")
local a = require("slang/async")
local uv = require("uv")

local func small(options){
  options.width = options.width or 320
  options.height = options.height or 200
  return webview.window(options)
}

t.group("webview"){
  t.test("calls from the page reach bound functions, with results and errors"){
    local got = null
    a.main(func(){
      local w = small({title: "calls", html: concat("<script>(async () => {",
        "  const sum = await slang.call('add', 2, 3);",
        "  let failed = null; try { await slang.call('fails'); } catch (e) { failed = e.message; }",
        "  let missing = null; try { await slang.call('nope'); } catch (e) { missing = e.message; }",
        "  const later = await slang.call('later', 'x');",
        "  const obj = await slang.call('echo', {a: [1, 'two', null, true]});",
        "  slang.send({sum, failed, missing, later, obj});",
        "})();</script>")})
      w:bind("add", func(x, y){ return x + y })
      w:bind("fails", func(){ error("on purpose") })
      w:bind("later", async func(v){ await a.sleep(20) return concat(v, "!") })
      w:bind("echo", func(v){ return v })
      local c = a.completer()
      w:on_message(func(v){ c.complete(v) })
      got = await a.timeout(c.future, 10000, "no answer from the page")
      w:close()
      await w.closed
    })
    assert(got.sum == 5 and got.later == "x!", concat("got ", got))
    assert(str.index_of(got.failed, "on purpose") >= 0, got.failed)
    assert(str.index_of(got.missing, "no slang function is bound as nope") >= 0, got.missing)
    assert(got.obj.a[0] == 1 and got.obj.a[1] == "two" and got.obj.a[3] == true)
  }
  t.test("pushes reach slang.on; eval, set_html and navigate work"){
    local seen = {}
    a.main(func(){
      local w = small({title: "push", html: "<script>slang.on(v => slang.send({echo: v}))</script>"})
      local next = null
      w:on_message(func(v){
        append(seen, v)
        if(next != null){ local n = next next = null n.complete(v) }
      })
      await a.sleep(300)
      next = a.completer()
      w:send({hello: "page"})
      assert((await a.timeout(next.future, 5000, "no echo")).echo.hello == "page")
      next = a.completer()
      w:eval("slang.send({from_eval: 6 * 7})")
      assert((await a.timeout(next.future, 5000, "no eval")).from_eval == 42)
      next = a.completer()
      w:set_html("<script>slang.send({fresh: true})</script>")
      assert((await a.timeout(next.future, 5000, "no fresh page")).fresh == true)
      w:set_title("renamed")
      w:close()
      await w.closed
      assert(not w:is_open())
      local r = pcall(func(){ w:navigate("about:blank") })
      assert(r[0] == "err" and str.index_of(r[1].message, "closed") >= 0)
    })
  }
  t.test("a slang/web app is served over app:// with no socket"){
    local got = null
    a.main(func(){
      local app = web.app()
      app:get("/", func(req){
        return web.html(concat("<script>(async () => {",
          "  const g = await (await fetch('/data?x=1')).json();",
          "  const p = await (await fetch('/echo', {method: 'POST', body: 'posted'})).text();",
          "  const s = await (await fetch('/static/missing.txt')).status;",
          "  slang.send({g, p, s});",
          "})();</script>"))
      })
      app:get("/data", func(req){ return web.json({x: req:query_params().x}) })
      app:post("/echo", func(req){ return concat("echo ", req.body) })
      local w = small({title: "app", app: app})
      local c = a.completer()
      w:on_message(func(v){ c.complete(v) })
      got = await a.timeout(c.future, 10000, "no answer over app://")
      w:close()
      await w.closed
    })
    assert(got.g.x == "1" and got.p == "echo posted" and got.s == 404, concat("got ", got))
  }
  t.test("libuv keeps running: timers, a loopback server, signals"){
    local ticks = 0
    local got = null
    local signal = null
    a.main(func(){
      local api = web.app()
      api:get("/ping", func(req){ return {status: 200, headers: {["Access-Control-Allow-Origin"]: "*"}, body: "pong"} })
      local s = api:listen("127.0.0.1", 0)
      local timer = uv.timer()
      timer:start(10, 10, func(){ ticks = ticks + 1 })
      local w = small({title: "loop", html: concat("<script>fetch('http://127.0.0.1:", string(s.port),
        "/ping').then(r => r.text()).then(t => slang.send(t))</script>")})
      local c = a.completer()
      w:on_message(func(v){ c.complete(v) })
      got = await a.timeout(c.future, 10000, "no fetch")
      // an unref'd signal watcher is heard while a window is open
      local sc = a.completer()
      local h = a.on_signal("SIGUSR2", func(name){ sc.complete(name) })
      uv.kill(uv.getpid(), "SIGUSR2")
      signal = await a.timeout(sc.future, 3000, "no signal")
      h:close()
      timer:close()
      w:close()
      await w.closed
      s.close()
      await s.done
    })
    assert(got == "pong" and signal == "SIGUSR2" and ticks > 3, concat("ticks ", string(ticks)))
  }
  t.test("several windows; the count follows them"){
    a.main(func(){
      local w1 = small({title: "one", html: "<p>one</p>"})
      local w2 = small({title: "two", html: "<p>two</p>"})
      assert(require("webview").window_count() == 2)
      w1:close()
      await w1.closed
      assert(require("webview").window_count() == 1 and w2:is_open())
      w2:close()
      await w2.closed
      assert(require("webview").window_count() == 0)
    })
  }
}
