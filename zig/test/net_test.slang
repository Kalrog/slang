// slang/net: servers and clients on loopback, with and without a
// simulated bad network
local t = require("slang/test")
local net = require("slang/net")
local time = require("slang/time")
local str = require("slang/string")

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
    t.raises(func(){ net.protocol({name: "x", messages: {connect: {"a"}}}) })
    local server = net.server({protocol: proto})
    t.raises(func(){ server:on("nope", func(){}) })
    local client = net.connect("127.0.0.1", server.port, {protocol: proto})
    t.raises(func(){ client:send("nope", {}) })
    t.raises(func(){ client:send("blob", "x" * 5000, {mode: "unreliable"}) })
    t.raises(func(){ client:send("blob", 1, {mode: "sideways"}) })
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

t.group("net: encrypted"){
  // what a host has queued to send (the simulated network holds it)
  local func on_the_wire(h){
    local all = {}
    for(let local p in values(h.sim_out)){
      append(all, p[1])
    }
    return str.join(all, "")
  }
  t.test("a client checks the server's key and password; messages go both ways"){
    local server = net.server({protocol: proto, secure: {password: "tunnel"}})
    local fp = server.fingerprint
    assert(len(fp) == 19 and str.substring(fp, 4, 5) == "-", fp)
    local heard = null
    local from = null
    local gone = null
    server:on("connect", func(peer){ peer:send("hello", {name: "server", level: 2}) })
    server:on("hello", func(peer, m){ from = m.name })
    server:on("disconnect", func(peer, reason){ gone = reason })
    // typed in another case, with spaces
    local client = net.connect("127.0.0.1", server.port, {protocol: proto, secure: {
      fingerprint: str.replace(str.upper(fp), "-", " "), password: "tunnel",
    }})
    client:on("hello", func(m){ heard = m })
    client:send("hello", {name: "client"})
    assert(until({server, client}, func(){ return heard != null and from != null }))
    assert(heard.level == 2 and from == "client")
    assert(server.peers[1].secure and client.fingerprint == fp)
    client:close()
    assert(until({server}, func(){ return gone != null }))
    assert(gone == "net: the client closed", gone)
    server:close()
  }
  t.test("nothing readable on the wire; changed packets are dropped"){
    local slow = {latency: 30}
    local server = net.server({protocol: proto, secure: true, simulate: slow})
    local client = net.connect("127.0.0.1", server.port, {protocol: proto, secure: true, simulate: slow})
    assert(until({server, client}, func(){ return client.connected }))
    local got = {}
    server:on("hello", func(peer, m){ append(got, m.name) })
    client:send("hello", {name: "the secret word"})
    client:flush()
    assert(len(client.sim_out) > 0)
    assert(not str.contains(on_the_wire(client), "the secret word"))
    // a bit flipped in the first packet: dropped, the message is resent
    local first = client.sim_out[0]
    local b = str.byte_at(first[1], len(first[1]) - 1)
    first[1] = concat(str.substring(first[1], 0, len(first[1]) - 1), str.from_bytes({b ^ 1}))
    assert(until({server, client}, func(){ return len(got) > 0 }))
    for(local i = 0; i < 20; i = i + 1){
      server:poll()
      client:poll()
      time.sleep(2)
    }
    assert(len(got) == 1 and got[0] == "the secret word", string(got))
    client:close()
    server:close()
  }
  t.test("reliable messages through loss, encrypted"){
    local bad = {latency: 5, jitter: 10, loss: 0.25}
    local server = net.server({simulate: bad, secure: true})
    local client = net.connect("127.0.0.1", server.port, {simulate: bad, secure: {fingerprint: server.fingerprint}})
    local got = {}
    server:on("n", func(peer, m){ append(got, m) })
    for(local i = 0; i < 60; i = i + 1){
      client:send("n", i)
    }
    assert(until({server, client}, func(){ return len(got) == 60 }), string(len(got)))
    for(local i = 0; i < 60; i = i + 1){
      assert(got[i] == i, string(got))
    }
    client:close()
    server:close()
  }
  t.test("turned away: the password, the key, one side not encrypting"){
    local cases = {
      {{secure: {password: "a"}}, {secure: {password: "b"}}, "net: wrong password"},
      {{secure: {password: "a"}}, {secure: true}, "net: wrong password"},
      {{secure: true}, {secure: {fingerprint: "0000-0000-0000-0000"}}, "is not the one expected"},
      {{secure: true}, {}, "net: the server takes only encrypted connections"},
      {{}, {secure: true}, "net: the server does not encrypt"},
    }
    for(let local k in values(cases)){
      local server = net.server(k[0])
      local client = net.connect("127.0.0.1", server.port, k[1])
      local reason = null
      client:on("disconnect", func(r){ reason = r })
      assert(until({server, client}, func(){ return reason != null }), k[2])
      assert(str.contains(reason, k[2]), reason)
      assert(count(server.peers) == 0)
      server:close()
    }
  }
  t.test("a kept key keeps the fingerprint"){
    local key = require("slang/crypto_core").random_bytes(32)
    local a = net.server({secure: {key: key}})
    local b = net.server({secure: {key: key}})
    local c = net.server({secure: true})
    assert(a.fingerprint == b.fingerprint and a.fingerprint != c.fingerprint)
    t.raises(func(){ net.server({secure: {key: "short"}}) })
    a:close()
    b:close()
    c:close()
  }
}

