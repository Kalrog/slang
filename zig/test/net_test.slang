// slang/net: servers and clients on loopback, with and without a
// simulated bad network
local t = require("slang/test")
local net = require("slang/net")
local time = require("slang/time")

// polls the hosts until done() is true; false after a few seconds
local func until(hosts, done){
  local deadline = time.clock() + 5000
  for(time.clock() < deadline){
    for(let local h in values(hosts)){
      h:poll()
    }
    if(done()){
      return true
    }
    time.sleep(1)
  }
  return false
}

local proto = net.protocol({name: "test", messages: {
  hello: {"name", "level"}, n: {"i"}, blob: "any", pos: {"x"},
}})

t.group("net"){
  t.test("a client connects, messages go both ways, it leaves"){
    local server = net.server({protocol: proto})
    local log = {}
    server:on("connect", func(peer){
      append(log, concat("connect ", peer.id))
      peer:send("hello", {name: "server", level: 1.5})
    })
    server:on("hello", func(peer, m){ append(log, concat("from ", peer.id, " ", m.name, " ", m.level)) })
    server:on("disconnect", func(peer, reason){ append(log, concat("gone ", peer.id, " ", reason)) })
    local client = net.connect("localhost", server.port, {protocol: proto})
    local heard = null
    client:on("hello", func(m){ heard = m })
    client:send("hello", {name: "client"})
    assert(until({server, client}, func(){ return heard != null and len(log) >= 2 }), string(log))
    assert(client.connected and client.id == 1)
    assert(heard.name == "server" and heard.level == 1.5, string(heard))
    assert(log[1] == "from 1 client null", string(log))
    assert(server.peers[1].address == concat("127.0.0.1:", string(server.peers[1].port)))
    client:close()
    assert(until({server}, func(){ return len(log) == 3 }), string(log))
    assert(log[2] == "gone 1 net: the client closed", string(log))
    server:close()
  }
  t.test("reliable messages arrive once each and in order through loss"){
    local bad = {latency: 5, jitter: 10, loss: 0.25}
    local server = net.server({simulate: bad})
    local client = net.connect("127.0.0.1", server.port, {simulate: bad})
    local got = {}
    local big = null
    server:on("n", func(peer, m){ append(got, m) })
    server:on("blob", func(peer, m){ big = m })
    for(local i = 0; i < 60; i = i + 1){
      client:send("n", i)
    }
    local text = "x" * 5000
    client:send("blob", {text: text})
    assert(until({server, client}, func(){ return big != null }), concat(string(len(got)), " arrived"))
    assert(len(got) == 60, string(len(got)))
    for(local i = 0; i < 60; i = i + 1){
      assert(got[i] == i, string(got))
    }
    assert(big.text == text, "the large message is whole")
    client:close()
    server:close()
  }
  t.test("sequenced messages: an older one is dropped"){
    local server = net.server({protocol: proto})
    local client = net.connect("127.0.0.1", server.port, {protocol: proto, simulate: {jitter: 30}})
    local xs = {}
    server:on("pos", func(peer, m){ append(xs, m.x) })
    assert(until({server, client}, func(){ return client.connected }))
    for(local i = 0; i < 30; i = i + 1){
      client:send("pos", {x: i}, {mode: "sequenced"})
      client:flush()
      time.sleep(1)
    }
    assert(until({server, client}, func(){ return len(xs) > 0 and xs[len(xs) - 1] == 29 }), string(xs))
    for(local i = 1; i < len(xs); i = i + 1){
      assert(xs[i] > xs[i - 1], string(xs))
    }
    client:close()
    server:close()
  }
  t.test("a client with another protocol is turned away"){
    local server = net.server({protocol: proto})
    local other = net.protocol({name: "test", messages: {hello: {"name"}}})
    local client = net.connect("127.0.0.1", server.port, {protocol: other})
    local reason = null
    client:on("disconnect", func(r){ reason = r })
    assert(until({server, client}, func(){ return reason != null }))
    assert(reason == "net: the client speaks another protocol", reason)
    assert(client.state == "closed" and count(server.peers) == 0)
    server:close()
  }
  t.test("misuse raises"){
    assert(pcall(net.protocol, {name: "x", messages: {connect: {"a"}}})[0] == "err")
    local server = net.server({protocol: proto})
    assert(pcall(func(){ server:on("nope", func(){}) })[0] == "err")
    local client = net.connect("127.0.0.1", server.port, {protocol: proto})
    assert(pcall(func(){ client:send("nope", {}) })[0] == "err")
    assert(pcall(func(){ client:send("blob", "x" * 5000, {mode: "unreliable"}) })[0] == "err")
    assert(pcall(func(){ client:send("blob", 1, {mode: "sideways"}) })[0] == "err")
    client:close()
    server:close()
  }
  t.test("a server that is not there"){
    local client = net.connect("127.0.0.1", 9, {timeout: 300})
    local reason = null
    client:on("disconnect", func(r){ reason = r })
    assert(until({client}, func(){ return reason != null }))
    assert(reason == "net: cannot connect: no answer", reason)
  }
  t.test("run polls from the event loop until the server closes"){
    local server = net.server({protocol: proto})
    local client = net.connect("127.0.0.1", server.port, {protocol: proto})
    local got = null
    local ticks = 0
    server:on("n", func(peer, m){ got = m.i })
    client:send("n", {i: 42})
    server:run({rate: 200, tick: func(dt){
      ticks = ticks + 1
      client:poll()
      if(got != null or ticks > 1000){
        client:close()
        server:close()
      }
    }})
    assert(got == 42, string(got))
  }
}
