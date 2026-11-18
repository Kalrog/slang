// the notebook server: its gate, the folder's API, and a notebook's
// session over a WebSocket (a kernel runs the cells: a process, or one in
// the page, which is the test here)
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local time = require("slang/time")
local json = require("slang/json")
local async = require("slang/async")
local http = require("slang/http")
local ws = require("slang/ws")
local server = require("notebook_server")

local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-notebook-server-test-",
  string(to_int(time.now()))
)

local func setup(){
  os.mkdir_all(concat(scratch, "/sub"))
  os.write_file(
    concat(scratch, "/first.md"),
    "# First\n\n```slang\nlocal n = 20\nn + 1\n```\n\nSome *text*.\n",
  )
  os.write_file(concat(scratch, "/data.txt"), "plain data\n")
  os.write_file(concat(scratch, "/.hidden.md"), "# no\n")
  os.write_file(concat(scratch, "/sub/deep.md"), "# Deep\n")
  return server.start({root: scratch, port: 0, token: "test-token"})
}

// the next message of a socket that is the event asked for
local func wait_for(socket, event, id){
  for(true){
    local m = async.await(async.timeout(socket.messages:next(), 10000))
    assert(not m.done, concat("the socket closed while waiting for ", event))
    local message = json.decode(m.value)
    if(message.event == event and (id == null or message.id == id)){
      return message
    }
  }
}

t.group("notebook server"){
  t.test("the gate: the token, the host, our own pages only"){
    async.main(func(){
      local s = setup()
      local base = concat("http://127.0.0.1:", string(s.port))
      local cookie = concat("slang_notebook_", string(s.port), "=test-token")
      assert(async.await(http.fetch(concat(base, "/"))).status == 403)
      assert(async.await(http.fetch(concat(base, "/api/files"))).status == 403)
      assert(async.await(http.fetch(concat(base, "/?token=wrong"))).status == 403)
      // the token in the URL becomes a cookie, and leaves the URL
      local r = async.await(http.fetch(concat(base, "/nb/first.md?token=test-token")))
      assert(r.status == 302 and r.headers["location"] == "/nb/first.md")
      local set = r.headers["set-cookie"]
      if(type(set) == "table"){
        set = set[0]
      }
      assert(str.starts_with(set, cookie))
      assert(str.index_of(set, "SameSite=Strict") > 0)
      r = async.await(http.fetch(concat(base, "/"), {headers: {Cookie: cookie}}))
      assert(r.status == 200 and str.index_of(r.body, "/static/app.js") > 0)
      // another page of the browser may not ask, cookie or not
      r = async.await(http.fetch(concat(base, "/api/files"), {
        headers: {Cookie: cookie, Origin: "http://evil.example"}
      }))
      assert(r.status == 403)
      r = async.await(http.fetch(concat(base, "/api/new"), {
        method: "POST", headers: {Cookie: cookie}, body: "{}"
      }))
      assert(r.status == 403, "a POST says where it comes from")
      // a name that points here is not us (DNS rebinding)
      local conn = async.await(async.connect("127.0.0.1", s.port))
      async.await(async.write(conn, concat(
        "GET / HTTP/1.1\r\nHost: evil.example:", string(s.port),
        "\r\nCookie: ", cookie, "\r\nConnection: close\r\n\r\n"
      )))
      local first = async.await(async.reader(conn):next())
      assert(str.starts_with(first.value, "HTTP/1.1 403"), first.value)
      conn:close()
      local refused = async.await(ws.connect(
        concat("ws://127.0.0.1:", string(s.port), "/ws?path=first.md"),
      ):then(func(socket){ return "open" }, func(e){ return e.status }))
      assert(refused == 403)
      s.close()
      async.await(s.done)
    })
    os.remove_all(scratch)
  }
  t.test("folders, new notebooks, and the files next to them"){
    async.main(func(){
      local s = setup()
      local base = concat("http://127.0.0.1:", string(s.port))
      local headers = {
        Cookie: concat("slang_notebook_", string(s.port), "=test-token"),
        Origin: base, ["Content-Type"]: "application/json"
      }
      local list = json.decode(
        async.await(http.fetch(concat(base, "/api/files"), {headers: headers})).body,
      )
      assert(len(list.folders) == 1 and list.folders[0].name == "sub")
      assert(len(list.notebooks) == 1 and list.notebooks[0].path == "first.md")
      local made = async.await(http.fetch(concat(base, "/api/new"), {
        method: "POST", headers: headers,
        body: json.encode({dir: "sub", name: "fresh"})
      }))
      assert(json.decode(made.body).path == "sub/fresh.md")
      assert(str.starts_with(os.read_file(concat(scratch, "/sub/fresh.md")), "# fresh\n"))
      made = async.await(http.fetch(concat(base, "/api/new"), {
        method: "POST", headers: headers,
        body: json.encode({dir: "sub", name: "fresh.md"})
      }))
      assert(made.status == 409)
      local func status(path){
        return async.await(http.fetch(concat(base, path), {headers: headers})).status
      }
      assert(async.await(
        http.fetch(concat(base, "/nb/data.txt"), {headers: headers}),
      ).body == "plain data\n")
      assert(status("/nb/sub/deep.md") == 200 and status("/nb/sub/") == 200)
      assert(status("/nb/../secret") == 404 and status("/nb/.hidden.md") == 404)
      assert(status("/api/files?dir=..") == 404)
      assert(status("/static/notebook.css") == 200 and status("/static/app.css") == 200)
      s.close()
      async.await(s.done)
    })
    os.remove_all(scratch)
  }
  t.test("a notebook: cells run in a kernel, edits are saved, pages follow each other"){
    async.main(func(){
      local s = setup()
      local options = {headers: {
        Cookie: concat("slang_notebook_", string(s.port), "=test-token"),
        Origin: concat("http://127.0.0.1:", string(s.port))
      }}
      local url = concat("ws://127.0.0.1:", string(s.port), "/ws?path=first.md")
      local socket = async.await(ws.connect(url, options))
      local nb = wait_for(socket, "notebook")
      assert(nb.title == "First" and nb.kernel == "none" and len(nb.cells) == 3)
      assert(nb.cells[1].type == "code" and nb.cells[1].spans[0][2] == "keyword")
      assert(str.index_of(nb.cells[2].html, "<em>text</em>") > 0)
      local code = nb.cells[1].id
      // run: the kernel starts, the cell's events come
      socket:send(json.encode({op: "run", ids: {code}}))
      local result = null
      for(result == null){
        local m = wait_for(socket, "cell", code)
        if(m.e.event == "result"){
          result = m.e.data["text/plain"]
        }
      }
      assert(result == "21")
      // a second page of the same notebook sees what the first one did
      local other = async.await(ws.connect(url, options))
      local seen = wait_for(other, "notebook")
      assert(seen.cells[1].outputs[0].data["text/plain"] == "21" and seen.cells[1].count == 1)
      // an edit: a new cell that uses the first one's local, then run
      socket:send(json.encode({op: "update", cells: {
        {id: nb.cells[0].id, type: "markdown", source: "# First"},
        {id: code, type: "code", source: "local n = 20\nn + 1"},
        {id: "new1", type: "code", source: "local t = null\nprint(n * 2, \"\\n\")\nt.x = 1"},
      }}))
      assert(len(wait_for(other, "cells").cells) == 3)
      wait_for(socket, "saved")
      local text = os.read_file(concat(scratch, "/first.md"))
      assert(str.index_of(text, "print(n * 2, \"\\n\")") > 0 and str.index_of(text, "Some") < 0, text)
      socket:send(json.encode({op: "run", ids: {"new1"}}))
      local failure = null
      local printed = ""
      for(failure == null){
        local m = wait_for(socket, "cell", "new1")
        if(m.e.event == "stream"){
          printed = concat(printed, m.e.text)
        } else if(m.e.event == "error"){
          failure = m.e.error
        }
      }
      assert(printed == "40\n" and failure.kind == "type")
      assert(failure.cell_line == 3, "the line in the cell")
      // the outputs are in the sidecar
      wait_for(socket, "saved")
      assert(str.index_of(os.read_file(concat(scratch, "/first.out.json")), "\"21\"") > 0)
      // highlighting and rendering are the server's
      socket:send(json.encode({op: "highlight", id: "new1", seq: 7, source: "local q"}))
      local tokens = wait_for(socket, "tokens", "new1")
      assert(tokens.seq == 7 and tokens.spans[0][2] == "keyword")
      socket:send(json.encode({op: "render", id: "x", seq: 1, source: "**b**"}))
      assert(wait_for(socket, "rendered").html == "<p><strong>b</strong></p>\n")
      // restart: the state is gone
      socket:send(json.encode({op: "restart"}))
      socket:send(json.encode({op: "run", ids: {"new1"}}))
      local kind = null
      for(kind == null){
        local m = wait_for(socket, "cell", "new1")
        if(m.e.event == "error"){
          kind = m.e.error.message
        }
      }
      assert(str.index_of(kind, "null") >= 0, kind)
      socket:send(json.encode({op: "clear"}))
      wait_for(socket, "saved")
      assert(not os.exists(concat(scratch, "/first.out.json")))
      s.close()
      async.await(s.done)
    })
    os.remove_all(scratch)
  }
  t.test("a kernel in the page: the server asks, the page's worker answers"){
    os.mkdir_all(scratch)
    os.write_file(concat(scratch, "/slang.project"), "{name: \"scratch\"}\n")
    os.write_file(concat(scratch, "/data.txt"), "plain data\n")
    os.write_file(
      concat(scratch, "/page.md"),
      "<!-- slang-notebook kernel: wasm -->\n\n```slang\n1 + 1\n```\n",
    )
    os.write_file(concat(scratch, "/plain.md"), "```slang\n1\n```\n")
    // (the server only hands slang.wasm out: the test is the page)
    local vm = concat(scratch, "/data.txt")
    async.main(func(){
      local s = server.start({root: scratch, port: 0, token: "test-token", vm: vm})
      assert(s.kernels[0] == "process" and s.kernels[1] == "wasm")
      local headers = {
        Cookie: concat("slang_notebook_", string(s.port), "=test-token"),
        Origin: concat("http://127.0.0.1:", string(s.port))
      }
      local base = concat("http://127.0.0.1:", string(s.port))
      // the page is isolated, and the worker's script is one classic script
      local shell = async.await(http.fetch(concat(base, "/nb/page.md"), {headers: headers}))
      assert(shell.headers["cross-origin-opener-policy"] == "same-origin")
      assert(shell.headers["cross-origin-embedder-policy"] == "credentialless")
      local worker = async.await(http.fetch(concat(base, "/static/web/worker.js"), {headers: headers}))
      assert(worker.status == 200 and str.index_of(worker.body, "async function run(") > 0)
      assert(async.await(http.fetch(concat(base, "/static/app.js"), {headers: headers})).status == 200)
      assert(async.await(http.fetch(concat(base, "/static/web/slang.wasm"), {headers: headers})).body == "plain data\n")

      local url = concat("ws://127.0.0.1:", string(s.port), "/ws?path=page.md")
      local socket = async.await(ws.connect(url, {headers: headers}))
      local nb = wait_for(socket, "notebook")
      assert(nb.kind == "wasm" and len(nb.kinds) == 2)
      local code = nb.cells[0].id
      socket:send(json.encode({op: "run", ids: {code}}))
      // the page is told to start a worker, with the project's files ...
      local start = wait_for(socket, "kernel_op")
      assert(start.op.op == "start" and start.op.cwd == "/work")
      assert(start.op.args[3] == "/work/page.md")
      assert(start.op.files["/work/data.txt"] == "plain data\n")
      assert(start.op.files["/pkg/notebook/bin/kernel_web.slang"] != null)
      // ... and then to run the cell, on the line it has in the file
      local execute = wait_for(socket, "kernel_op")
      assert(execute.op.op == "execute" and execute.op.code == "1 + 1")
      assert(execute.op.line == 3 and execute.kernel == start.kernel)
      local func say(e){
        socket:send(json.encode({op: "kernel_event", kernel: start.kernel, e: e}))
      }
      say({event: "ready", project: "/work/slang.project"})
      // (the project is named as it is on this machine)
      local told = wait_for(socket, "kernel")
      assert(told.project == concat(s.root, "/slang.project"), string(told.project))
      say({event: "start", id: code})
      say({event: "stream", name: "stdout", text: "printed\n"})
      say({event: "result", id: code, data: {["text/plain"]: "2"}})
      say({event: "done", id: code, status: "ok", ms: 1})
      local seen = {}
      for(seen.done == null){
        local m = wait_for(socket, "cell", code)
        seen[m.e.event] = m.e
      }
      assert(seen.stream.text == "printed\n" and seen.result.data["text/plain"] == "2")
      // what another kernel's page says is not taken
      socket:send(json.encode({op: "kernel_event", kernel: start.kernel + 7, e: {
        event: "result", id: code, data: {["text/plain"]: "no"}
      }}))
      wait_for(socket, "saved")
      assert(str.index_of(os.read_file(concat(scratch, "/page.out.json")), "\"no\"") < 0)
      // the page leaves: its kernel is gone with it
      socket:send(json.encode({op: "run", ids: {code}}))
      wait_for(socket, "kernel_op")
      socket:close()
      local other = async.await(ws.connect(url, {headers: headers}))
      local again = wait_for(other, "notebook")
      for(again.kernel != "dead"){
        again = wait_for(other, "kernel")
        again.kernel = again.status
      }
      // a notebook that does not say runs in a process; a switch is saved
      local plain = async.await(ws.connect(
        concat("ws://127.0.0.1:", string(s.port), "/ws?path=plain.md"), {headers: headers},
      ))
      assert(wait_for(plain, "notebook").kind == "process")
      plain:send(json.encode({op: "kernel", kind: "wasm"}))
      assert(wait_for(plain, "kernel").kind == "wasm")
      wait_for(plain, "saved")
      assert(str.starts_with(
        os.read_file(concat(scratch, "/plain.md")), "<!-- slang-notebook kernel: wasm -->\n\n```slang",
      ))
      s.close()
      async.await(s.done)
      // one kind for every notebook, whatever they say
      local pinned = server.start({
        root: scratch, port: 0, token: "test-token", kernel: "process", vm: vm
      })
      local third = async.await(ws.connect(
        concat("ws://127.0.0.1:", string(pinned.port), "/ws?path=page.md"),
        {headers: {
          Cookie: concat("slang_notebook_", string(pinned.port), "=test-token"),
          Origin: concat("http://127.0.0.1:", string(pinned.port))
        }},
      ))
      local view = wait_for(third, "notebook")
      assert(view.kind == "process" and len(view.kinds) == 1)
      pinned.close()
      async.await(pinned.done)
    })
    os.remove_all(scratch)
  }
}
