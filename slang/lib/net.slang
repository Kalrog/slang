// slang/net: networking for games. A server and its clients exchange
// messages over UDP: named messages with a table of data each, sent
// reliably (resent until they arrive, in order), unreliably (fire and
// forget, for what is out of date soon anyway) or sequenced (unreliable,
// and an older one of the same name is dropped once a newer one arrived).
//
//   local net = require("slang/net")
//   local server = net.server({port: 7777})
//   server:on("connect", func(peer){ peer:send("welcome", {id: peer.id}) })
//   server:on("move", func(peer, m){ players[peer.id].x = m.x })
//   server:on("disconnect", func(peer, reason){ delete(players, peer.id) })
//
//   local client = net.connect("127.0.0.1", 7777)
//   client:on("welcome", func(m){ my_id = m.id })
//   client:send("move", {x: 3}, {mode: "unreliable"})
//
//   for(not rl.window.should_close){
//     server:poll()      // receive, run the handlers, send what is queued
//     client:poll()
//     ...
//   }
//
// Nothing happens behind the program's back: messages arrive, handlers run
// and queued messages go out in [Server.poll] and [Client.poll], which a
// game calls once per frame. A server without a frame loop calls
// [Server.run] instead. Code that runs inside slang/async (or uv.run) may
// poll too: the loop is running already, so poll only handles what arrived.
//
// A [Protocol] names the messages up front and the fields of each, so that
// a message travels as its number and its values without the field names;
// both sides must use the same one (a client with another is turned away).
// Without one, a message travels with its name and its whole table.
//
// Message data is anything slang/encoding's binary form takes: null,
// booleans, numbers, strings and tables of them. A reliable message may be
// large (it is split into packets); an unreliable one must fit in one
// packet ([max_unreliable] bytes encoded).
//
// options.simulate makes a host's network worse on purpose, to see how a
// game plays with lag and loss: every packet it sends or receives is
// delayed by latency ms plus up to jitter ms (so packets also overtake each
// other), and dropped with the probability loss.
//
// options.secure encrypts a connection: a server with it takes only
// encrypted ones, a client with it connects only encrypted. Every packet
// after the handshake is sealed (ChaCha20-Poly1305, keys from X25519 key
// agreement, new for every connection): nobody on the way reads it, and
// what was changed, replayed or sent in a peer's name is dropped. The
// server has a key of its own ([ServerSecure].key, random by default); its
// [Server.fingerprint] is short text that a client can be given
// ([ClientSecure].fingerprint) to know it reached that server and nobody
// in between. A password, when the server has one, must be the client's
// too. A server answers a connection attempt with a cookie first, so an
// address that is not the sender's gets nothing set up for it.
//
//   local server = net.server({port: 7777, secure: {password: "tunnel"}})
//   print(server.fingerprint)                 // "k3mq-7x2b-..." for players
//   local client = net.connect(ip, 7777, {secure: {
//     fingerprint: "k3mq-7x2b-...", password: "tunnel",
//   }})
//
// Without secure there is no encryption or authentication: anyone who can
// reach the port can connect. Either way a peer's messages are what it
// chose to send: servers check what clients tell them.
local uv = require("uv")
local crypto = require("slang/crypto_core")
local enc = require("slang/encoding")
local math = require("slang/math")
local str = require("slang/string")
local table = require("slang/table")

local net = {}

local encode = enc.binary.encode
local decode = enc.binary.decode

// packet kinds: the first element of every packet
local CONNECT = 0
local ACCEPT = 1
local REJECT = 2
local DATA = 3
local DISCONNECT = 4
// the encrypted handshake: the client's hello, the server's challenge
// (a cookie and its key), the client's answer (its key and a proof)
local HELLO = 5
local CHALLENGE = 6
local SECURE = 7

local MAGIC = "slang/net 1"
// the encoded messages that go into one packet, at most
local BUDGET = 1200
// a reliable message longer than this travels in parts
local PART = 1024
// reliable messages sent and not yet acknowledged, at most
local IN_FLIGHT = 1024
// a reliable message this far ahead of the next expected one is dropped
local WINDOW = 4096
// the largest reliable message (its parts together)
local MAX_MESSAGE = 16 * 1024 * 1024
// a packet goes out at least this often (it carries the acknowledgements)
local KEEPALIVE = 100
local CONNECT_RETRY = 200
// a connection that goes away says so this many times (it may be lost)
local GOODBYES = 3
// datagrams waiting for poll, at most
local INBOX = 8192
// the type of a part of a reliable message that is not the last
local PART_TYPE = -1

// max_unreliable: the largest unreliable or sequenced message, encoded
net.max_unreliable = BUDGET - 64

local MODES = {reliable: true, unreliable: true, sequenced: true}
local CIPHER = "chacha20-poly1305"
// a cookie is good for this long (ms) and the period after
local COOKIE_PERIOD = 10000
local EVENTS = {connect: true, disconnect: true}

local func now(){
  return uv.hrtime() / 1000000
}

local func text_or(v, default){
  if(type(v) == "string"){
    return v
  }
  return default
}

// whether s is an IPv4 address (digits and dots) or an IPv6 one (colons)
local func is_ip(s){
  if(str.contains(s, ":")){
    return true
  }
  for(local i = 0; i < len(s); i = i + 1){
    local b = str.byte_at(s, i)
    if(b != '.' and (b < '0' or b > '9')){
      return false
    }
  }
  return len(s) > 0
}

// ------------------------------------------------------------ keys

// the 12-byte iv of packet s: the lane (0 packets, 1 the handshake), then
// s, big-endian (keys are new for every connection and each way, and s
// only grows: an iv is never used twice with a key)
local func iv_of(s, lane){
  return str.from_bytes({
    0, 0, 0, lane, (s >> 56) & 255, (s >> 48) & 255, (s >> 40) & 255, (s >> 32) & 255,
    (s >> 24) & 255, (s >> 16) & 255, (s >> 8) & 255, s & 255,
  })
}

local func sha(...parts){
  return crypto.hash("sha256", str.join(parts, ""))
}

// HKDF-SHA256 (RFC 5869), one block: 32 bytes of key from ikm
local func hkdf(ikm, salt, info){
  return crypto.hmac("sha256", crypto.hmac("sha256", salt, ikm), concat(info, "\x01"))
}

local func psk_of(password){
  if(password == null or password == ""){
    return ""
  }
  if(type(password) != "string"){
    raise(error.new(error.kinds.argument, "net: secure.password is a string"))
  }
  return sha("slang/net password ", password)
}

// what both sides of a handshake hash into its keys
local func transcript(signature, nonce, server_public, client_public){
  return sha(MAGIC, "\n", signature, "\n", string(nonce), "\n", server_public, client_public)
}

local B32 = "0123456789abcdefghjkmnpqrstvwxyz"

// fingerprint(public: string) -> string
// The short text that names a server's key ([Server.fingerprint]): 80
// bits of its hash in 16 letters and digits, four groups of four.
func net.fingerprint(public){
  local d = sha("slang/net key ", public)
  local out = {}
  local acc = 0
  local bits = 0
  for(local i = 0; i < 10; i = i + 1){
    acc = (acc << 8) | str.byte_at(d, i)
    bits = bits + 8
    for(bits >= 5){
      bits = bits - 5
      local k = (acc >> bits) & 31
      append(out, str.substring(B32, k, k + 1))
      if(len(out) % 5 == 4 and len(out) < 19){
        append(out, "-")
      }
    }
    acc = acc & ((1 << bits) - 1)
  }
  return str.join(out, "")
}

// a fingerprint as typed: any case, the dashes and spaces left out, the
// letters that look like digits read as those
local func plain_fingerprint(text){
  local s = str.lower(text)
  for(let local r in values({{"-", ""}, {" ", ""}, {"o", "0"}, {"i", "1"}, {"l", "1"}})){
    s = str.replace(s, r[0], r[1])
  }
  return s
}

local func secure_of(o, what){
  if(o == null or o == false){
    return null
  }
  if(o == true){
    return {}
  }
  if(type(o) != "table"){
    raise(error.new(error.kinds.argument, concat("net: options.secure is true or ", what)))
  }
  return o
}

// ------------------------------------------------------------ protocols

local protocol_methods = {}

// The messages a server and its clients exchange: [protocol] makes one.
// type Protocol = {name: string, signature: string}
// [name]: the name it was made with
// [signature]: the name and every message with its fields, as text; a
//   client is accepted only with the server's signature
local protocol_meta = {__type: "net.Protocol", __index: protocol_methods}

// protocol(definition: {name: string, messages: {string: {string} | string}}) -> Protocol
// A protocol: definition.messages maps each message name to the list of
// its fields, or to "any" for a message whose data travels whole (a list,
// say, or a table whose keys vary). Fields that are null are left out.
//   net.protocol({name: "arena", messages: {
//     move: {"dx", "dy"}, chat: {"text"}, state: "any",
//   }})
func net.protocol(definition){
  if(type(definition) != "table" or type(definition.name) != "string"){
    raise(error.new(error.kinds.argument, "net: a protocol needs a name"))
  }
  local names = {}
  for(let local name in keys(definition.messages or {})){
    if(type(name) != "string"){
      raise(error.new(error.kinds.argument, "net: message names are strings"))
    }
    if(EVENTS[name]){
      raise(error.new(
        error.kinds.argument, concat("net: \"", name, "\" is an event, not a message name"),
      ))
    }
    append(names, name)
  }
  table.sort(names)
  local p = {
    @meta: protocol_meta, name: definition.name, ids: {}, names: names, fields: {},
  }
  local parts = {definition.name}
  for(local id = 0; id < len(names); id = id + 1){
    local name = names[id]
    local fields = definition.messages[name]
    p.ids[name] = id
    if(fields == "any"){
      append(parts, concat(name, "=any"))
    } else if(type(fields) == "table"){
      for(let local f in values(fields)){
        if(type(f) != "string"){
          raise(error.new(error.kinds.argument, concat("net: the fields of ", name, " are strings")))
        }
      }
      p.fields[id] = fields
      append(parts, concat(name, "(", str.join(fields, ","), ")"))
    } else {
      raise(error.new(
        error.kinds.argument, concat("net: message ", name, " needs a list of fields or \"any\""),
      ))
    }
  }
  p.signature = str.join(parts, ";")
  return p
}

// a message's type on the wire and its data encoded
local func pack(proto, name, data){
  if(proto == null){
    if(type(name) != "string"){
      raise(error.new(error.kinds.argument, "net: a message name is a string"))
    }
    return {name, encode(data)}
  }
  local id = proto.ids[name]
  if(id == null){
    raise(error.new(
      error.kinds.argument, concat("net: ", proto.name, " has no message ", string(name)),
    ))
  }
  local fields = proto.fields[id]
  if(fields == null){
    return {id, encode(data)}
  }
  local p = {}
  if(data != null){
    for(local i = 0; i < len(fields); i = i + 1){
      local v = data[fields[i]]
      if(v != null){
        p[i] = v
      }
    }
  }
  return {id, encode(p)}
}

// the name and data of a message from the wire, or null when it makes no
// sense (an unknown type, data that does not decode)
local func unpack(proto, kind, bytes){
  if(type(bytes) != "string"){
    return null
  }
  local data = null
  local ok = false
  try {
    data = decode(bytes)
    ok = true
  } catch {}
  if(not ok){
    return null
  }
  if(proto == null){
    if(type(kind) != "string" or EVENTS[kind]){
      return null
    }
    return {kind, data}
  }
  if(type(kind) != "int"){
    return null
  }
  local name = proto.names[kind]
  if(name == null){
    return null
  }
  local fields = proto.fields[kind]
  if(fields == null){
    return {name, data}
  }
  if(type(data) != "table"){
    return null
  }
  local m = {}
  for(local i = 0; i < len(fields); i = i + 1){
    m[fields[i]] = data[i]
  }
  return {name, m}
}

// ------------------------------------------------------------ hosts

// What a server and a client share: the socket, the handlers, the
// simulated network and what arrived since the last poll.
local func new_host(proto, options){
  if(proto != null and type(proto) != "net.Protocol"){
    raise(error.new(error.kinds.argument, "net: options.protocol must come from net.protocol"))
  }
  local h = {
    udp: uv.udp(), proto: proto, handlers: {}, inbox: {},
    timeout: options.timeout or 5000, closed: false,
    // the simulated network: packets on their way, each {at, data, ip, port}
    sim: options.simulate, sim_out: {}, sim_in: {},
  }
  if(h.sim != null){
    h.sim = {
      latency: h.sim.latency or 0, jitter: h.sim.jitter or 0, loss: h.sim.loss or 0,
    }
  }
  return h
}

local func listen(h){
  h.udp:recv_start(func(err, data, from){
    if(err == null and data != null and len(h.inbox) < INBOX){
      append(h.inbox, {data, from.ip, from.port})
    }
  })
}

local func delay(sim){
  return sim.latency + math.random() * sim.jitter
}

local func send_raw(h, data, ip, port){
  if(h.closed){
    return
  }
  // (a datagram that cannot be sent is as good as lost)
  try { h.udp:send(data, ip, port) } catch {}
}

local func send_packet(h, packet, ip, port){
  local data = encode(packet)
  if(h.sim == null){
    send_raw(h, data, ip, port)
  } else if(math.random() >= h.sim.loss){
    append(h.sim_out, {now() + delay(h.sim), data, ip, port})
  }
}

// the packets of a simulated queue that are due, in the order they are due
local func due(queue, t){
  local ready = {}
  local rest = {}
  for(let local p in values(queue)){
    if(p[0] <= t){
      append(ready, p)
    } else {
      append(rest, p)
    }
  }
  table.sort(ready, func(a, b){ return a[0] < b[0] })
  return {ready, rest}
}

// the datagrams to handle now: what arrived, through the simulated network
local func take_inbox(h, t){
  local inbox = h.inbox
  h.inbox = {}
  if(h.sim == null){
    return inbox
  }
  for(let local d in values(inbox)){
    if(math.random() >= h.sim.loss){
      append(h.sim_in, {t + delay(h.sim), d[0], d[1], d[2]})
    }
  }
  local d = due(h.sim_in, t)
  h.sim_in = d[1]
  local ready = {}
  for(let local p in values(d[0])){
    append(ready, {p[1], p[2], p[3]})
  }
  return ready
}

local func send_delayed(h, t){
  if(h.sim == null or len(h.sim_out) == 0){
    return
  }
  local d = due(h.sim_out, t)
  h.sim_out = d[1]
  for(let local p in values(d[0])){
    send_raw(h, p[1], p[2], p[3])
  }
}

// runs the loop for what has arrived, unless it runs already
local func pump(){
  if(not uv.running()){
    uv.run("nowait")
  }
}

local func on(h, event, handler){
  if(type(event) != "string"){
    raise(error.new(
      error.kinds.argument, "net: on(event, handler) needs an event or message name",
    ))
  }
  if(handler != null and type(handler) != "function"){
    raise(error.new(error.kinds.argument, "net: a handler is a function"))
  }
  if(h.proto != null and not EVENTS[event] and h.proto.ids[event] == null){
    raise(error.new(error.kinds.argument, concat("net: ", h.proto.name, " has no message ", event)))
  }
  h.handlers[event] = handler
}

// ------------------------------------------------------------ connections

// A connection's state, on either side: packets numbered by seq and
// acknowledged by number (ack, the newest received, and bits, the 32
// before it); reliable messages numbered by rid, kept until a packet that
// carried them is acknowledged, resent while not.
local func new_conn(h, ip, port, t){
  return {
    host: h, ip: ip, port: port, address: concat(ip, ":", string(port)),
    state: "connecting", rtt: 100, loss: 0,
    seq: 0, sent: {}, sent_first: 0,
    recv_high: -1, recv_bits: 0,
    rid_next: 0, rel_first: 0, out_rel: {}, out_unrel: {}, out_seq: {},
    in_next: 0, in_buf: {}, parts: null, parts_size: 0, seq_last: {},
    last_recv: t, last_send: -1, need_ack: false,
  }
}

local func queue_packed(c, packed, mode){
  local kind = packed[0]
  local data = packed[1]
  if(mode == "reliable"){
    for(len(data) > PART){
      c.out_rel[c.rid_next] = {rid: c.rid_next, kind: PART_TYPE, data: str.substring(data, 0, PART), sent_at: -1}
      c.rid_next = c.rid_next + 1
      data = str.substring(data, PART)
    }
    c.out_rel[c.rid_next] = {rid: c.rid_next, kind: kind, data: data, sent_at: -1}
    c.rid_next = c.rid_next + 1
  } else {
    if(len(data) > net.max_unreliable){
      raise(error.new(error.kinds.argument, concat(
        "net: an ", mode, " message must fit in a packet (", string(len(data)),
        " bytes encoded, ", string(net.max_unreliable), " at most)"
      ), {size: len(data)}))
    }
    append(if(mode == "unreliable"){ c.out_unrel } else { c.out_seq }, {kind, data})
  }
}

local func mode_of(options){
  local mode = options != null and options.mode or "reliable"
  if(not MODES[mode]){
    raise(error.new(error.kinds.argument, concat(
      "net: mode is \"reliable\", \"unreliable\" or \"sequenced\", not ", string(mode),
    )))
  }
  return mode
}

local func resend_after(c){
  return math.max(40, c.rtt * 1.25 + 15)
}

local func acked(c, s, t){
  local p = c.sent[s]
  if(p == null){
    return
  }
  delete(c.sent, s)
  c.rtt = c.rtt + (t - p.at - c.rtt) * 0.1
  c.loss = c.loss * 0.95
  for(let local rid in values(p.rids)){
    delete(c.out_rel, rid)
  }
  for(c.rel_first < c.rid_next and c.out_rel[c.rel_first] == null){
    c.rel_first = c.rel_first + 1
  }
}

// one packet: the messages in rel (flat rid, kind, data), unrel and seqd
// (flat kind, data); rids are the reliable ones it carries
local func send_data(c, rel, unrel, seqd, rids, t){
  local s = c.seq
  c.seq = s + 1
  c.sent[s] = {at: t, rids: rids}
  // packets that can no longer be acknowledged were lost
  for(c.sent_first < s - 32){
    if(c.sent[c.sent_first] != null){
      delete(c.sent, c.sent_first)
      c.loss = c.loss * 0.95 + 0.05
    }
    c.sent_first = c.sent_first + 1
  }
  if(c.send_key == null){
    send_packet(c.host, {DATA, s, c.recv_high, c.recv_bits, rel, unrel, seqd}, c.ip, c.port)
  } else {
    local body = encode({c.recv_high, c.recv_bits, rel, unrel, seqd})
    send_packet(c.host, {DATA, s, crypto.encrypt(CIPHER, c.send_key, iv_of(s, 0), body)}, c.ip, c.port)
  }
  c.last_send = t
  c.need_ack = false
}

// sends what is queued: the reliable messages that are new or due again,
// then the others, as many packets as it takes; an empty one when the
// other side waits for an acknowledgement or has heard nothing for a while
local func flush(c, t){
  if(c.state != "connected"){
    return
  }
  local rel = {}
  local unrel = {}
  local seqd = {}
  local rids = {}
  local size = 0
  local sent = false
  local again = resend_after(c)
  local last = math.min(c.rid_next, c.rel_first + IN_FLIGHT)
  for(local rid = c.rel_first; rid < last; rid = rid + 1){
    local m = c.out_rel[rid]
    if(m != null and (m.sent_at < 0 or t - m.sent_at >= again)){
      local cost = len(m.data) + 12
      if(size + cost > BUDGET and size > 0){
        send_data(c, rel, unrel, seqd, rids, t)
        sent = true
        rel = {}
        rids = {}
        size = 0
      }
      append(rel, m.rid)
      append(rel, m.kind)
      append(rel, m.data)
      append(rids, m.rid)
      m.sent_at = t
      size = size + cost
    }
  }
  for(let local queue in values({c.out_unrel, c.out_seq})){
    local into = if(queue == c.out_unrel){ unrel } else { seqd }
    for(let local m in values(queue)){
      local cost = len(m[1]) + 8
      if(size + cost > BUDGET and size > 0){
        send_data(c, rel, unrel, seqd, rids, t)
        sent = true
        rel = {}
        unrel = {}
        seqd = {}
        rids = {}
        size = 0
        into = if(queue == c.out_unrel){ unrel } else { seqd }
      }
      append(into, m[0])
      append(into, m[1])
      size = size + cost
    }
  }
  c.out_unrel = {}
  c.out_seq = {}
  if(size > 0 or (not sent and (c.need_ack or t - c.last_send >= KEEPALIVE))){
    send_data(c, rel, unrel, seqd, rids, t)
  }
}

// a message arrived: the handler of its name runs
local func deliver(c, kind, bytes){
  local h = c.host
  local m = unpack(h.proto, kind, bytes)
  if(m == null){
    return
  }
  local handler = h.handlers[m[0]]
  if(handler == null){
    return
  }
  if(h.is_server){
    handler(c.peer, m[1])
  } else {
    handler(m[1])
  }
}

local close_conn = null

local func deliver_reliable(c, m){
  if(type(m.data) != "string"){
    return
  }
  if(m.kind == PART_TYPE){
    if(c.parts == null){
      c.parts = {}
    }
    append(c.parts, m.data)
    c.parts_size = c.parts_size + len(m.data)
    if(c.parts_size > MAX_MESSAGE){
      close_conn(c, "net: a message was too large", true)
    }
    return
  }
  local data = m.data
  if(c.parts != null){
    append(c.parts, data)
    data = str.join(c.parts, "")
    c.parts = null
    c.parts_size = 0
  }
  deliver(c, m.kind, data)
}

// a sealed packet's contents (DATA, DISCONNECT: {kind, s, sealed}), or
// null when it is not what the other side sealed
local func unseal(c, p){
  if(type(p[1]) != "int" or type(p[2]) != "string"){
    return null
  }
  return crypto.decrypt(CIPHER, c.recv_key, iv_of(p[1], 0), p[2])
}

// a DATA packet as it was sent, opened on an encrypted connection; null
// when it does not open
local func opened(c, p){
  if(c.recv_key == null){
    return p
  }
  local body = unseal(c, p)
  local q = if(body == null){ null } else { try { decode(body) } catch { null } }
  if(type(q) != "table"){
    return null
  }
  return {DATA, p[1], q[0], q[1], q[2], q[3], q[4]}
}

// a DISCONNECT's reason, or null when it is not the other side's
local func goodbye_reason(c, p){
  if(c.recv_key == null){
    return text_or(p[1], "disconnected")
  }
  return text_or(unseal(c, p), null)
}

// a DATA packet from the other side of c
local func on_data(c, p, t){
  p = opened(c, p)
  if(p == null){
    return
  }
  local s = p[1]
  local ack = p[2]
  local bits = p[3]
  local rel = p[4]
  local unrel = p[5]
  local seqd = p[6]
  if(type(s) != "int" or type(ack) != "int" or type(bits) != "int"
     or type(rel) != "table" or type(unrel) != "table" or type(seqd) != "table"){
    return
  }
  // a packet seen before (or too old to tell) is dropped whole
  if(s > c.recv_high){
    local shift = s - c.recv_high
    if(c.recv_high < 0 or shift > 32){
      c.recv_bits = 0
    } else {
      c.recv_bits = ((c.recv_bits << shift) | (1 << (shift - 1))) & 0xFFFF_FFFF
    }
    c.recv_high = s
  } else {
    local back = c.recv_high - s
    if(back == 0 or back > 32 or (c.recv_bits & (1 << (back - 1))) != 0){
      return
    }
    c.recv_bits = c.recv_bits | (1 << (back - 1))
  }
  c.last_recv = t
  acked(c, ack, t)
  for(local i = 0; i < 32; i = i + 1){
    if((bits & (1 << i)) != 0){
      acked(c, ack - 1 - i, t)
    }
  }
  if(len(rel) > 0){
    c.need_ack = true
  }
  for(local i = 0; i + 2 < len(rel); i = i + 3){
    local rid = rel[i]
    if(type(rid) == "int" and rid >= c.in_next and rid < c.in_next + WINDOW and c.in_buf[rid] == null){
      c.in_buf[rid] = {kind: rel[i + 1], data: rel[i + 2]}
    }
  }
  for(c.state == "connected" and c.in_buf[c.in_next] != null){
    local m = c.in_buf[c.in_next]
    delete(c.in_buf, c.in_next)
    c.in_next = c.in_next + 1
    deliver_reliable(c, m)
  }
  for(local i = 0; i + 1 < len(unrel) and c.state == "connected"; i = i + 2){
    deliver(c, unrel[i], unrel[i + 1])
  }
  for(local i = 0; i + 1 < len(seqd) and c.state == "connected"; i = i + 2){
    local kind = seqd[i]
    local last = c.seq_last[kind]
    if(last == null or s > last){
      c.seq_last[kind] = s
      deliver(c, kind, seqd[i + 1])
    }
  }
}

// ------------------------------------------------------------ peers

local peer_methods = {}
local peer_get = {}

// A client as the server sees it. A program may keep its own fields on a
// peer (peer.player = ...), apart from these.
// type Peer = {id: int, address: string, ip: string, port: int, server: Server,
//   send: func(name: string, data?: any, options?: SendOptions),
//   disconnect: func(reason?: string)}
// [id]: a number the server gave it, from 1, not reused while the server runs
// [address]: "ip:port"
// [server]: the [Server] it is connected to
local peer_meta = {__type: "net.Peer", __index: peer_methods, __get: peer_get}

// rtt(self) -> number
// The round-trip time in ms, smoothed.
func peer_get.rtt(peer){
  return peer.conn.rtt
}

// loss(self) -> number
// The part of the packets sent to it that were lost lately, 0 to 1.
func peer_get.loss(peer){
  return peer.conn.loss
}

// connected(self) -> bool
// Whether it is still connected.
func peer_get.connected(peer){
  return peer.conn.state == "connected"
}

// How a message goes. Reliable messages arrive once each, in the order they
// were sent; unreliable ones may not arrive, or twice never but out of
// order; sequenced ones like unreliable, minus any older than the newest
// of the same name that arrived.
// type SendOptions = {mode?: string}
// [mode]: "reliable" (the default), "unreliable" or "sequenced"

// send(name: string, data?: any, options?: SendOptions)
// Queues a message for this peer; it goes out with the next poll.
func peer_methods.send(peer, name, data, options){
  local c = peer.conn
  if(c.state != "connected"){
    return
  }
  queue_packed(c, pack(c.host.proto, name, data), mode_of(options))
}

// disconnect(reason?: string)
// Ends the connection: the client hears why, and the server's
// "disconnect" handler runs now.
func peer_methods.disconnect(peer, reason){
  close_conn(peer.conn, reason or "disconnected by the server", true)
}

// ------------------------------------------------------------ servers

local server_methods = {}
local server_get = {}

// A server: [server] makes one.
// type Server = {port: int, peers: {int: Peer}, protocol: Protocol?,
//   on: func(event: string, handler: function?),
//   broadcast: func(name: string, data?: any, options?: BroadcastOptions),
//   poll: func(), flush: func(), run: func(options?: RunOptions), close: func()}
// [port]: the port it listens on (the one picked, for port 0)
// [peers]: the connected clients by id; a program reads it, net changes it
// [protocol]: the [Protocol] of its options
// [fingerprint]: its key's, with options.secure
local server_meta = {__type: "net.Server", __index: server_methods, __get: server_get}

// Options of [server].
// type ServerOptions = {port?: int, host?: string, protocol?: Protocol,
//   max_peers?: int, timeout?: number, simulate?: Simulate,
//   secure?: bool | ServerSecure}
// [port]: the UDP port (0, the default, picks a free one)
// [host]: the address to listen on, "0.0.0.0" (every IPv4 one) by default
// [protocol]: the messages; without one, names and whole tables travel
// [max_peers]: more clients are turned away ("server full"), 32 by default
// [timeout]: a client not heard from for this many ms is gone (5000)
// [simulate]: a worse network, for testing
// [secure]: only encrypted connections (true, or with a key or password)

// What an encrypting server has: its key and a password.
// type ServerSecure = {key?: string, password?: string}
// [key]: its X25519 secret, 32 bytes (crypto_core.random_bytes(32)); keep
//   one to keep the [Server.fingerprint]. A new one by default
// [password]: clients must have it too

// The simulated network of options.simulate.
// type Simulate = {latency?: number, jitter?: number, loss?: number}
// [latency]: ms added to every packet, each way
// [jitter]: up to this many ms more, at random
// [loss]: the probability that a packet is dropped, 0 to 1

// server(options?: ServerOptions) -> Server
// A server, listening right away. Its handlers ([Server.on]) run in
// [Server.poll]: "connect" gets the [Peer], "disconnect" the peer and the
// reason, a message the peer and its data.
func net.server(options){
  options = options or {}
  local h = new_host(options.protocol, options)
  h.is_server = true
  h.by_address = {}
  h.peers = {}
  h.next_id = 1
  h.max_peers = options.max_peers or 32
  local sec = secure_of(options.secure, "{key?, password?}")
  if(sec != null){
    local secret = sec.key or crypto.random_bytes(32)
    if(type(secret) != "string" or len(secret) != 32){
      raise(error.new(error.kinds.argument, "net: secure.key is 32 bytes"))
    }
    h.secure = {
      secret: secret, public: crypto.x25519(secret), psk: psk_of(sec.password),
      cookie_key: crypto.random_bytes(32),
    }
  }
  h.@meta = server_meta
  h.udp:bind(options.host or "0.0.0.0", options.port or 0)
  h.port = h.udp:getsockname().port
  listen(h)
  return h
}

// protocol(self) -> Protocol?
func server_get.protocol(h){
  return h.proto
}

// fingerprint(self) -> string?
// The short text that names this server's key (see [fingerprint]), for
// clients to check that they reached it; null without options.secure.
func server_get.fingerprint(h){
  if(h.secure == null){
    return null
  }
  return net.fingerprint(h.secure.public)
}

// on(event: string, handler: function?)
// Sets the handler of an event ("connect", "disconnect") or a message
// name, replacing the one before; null removes it.
func server_methods.on(h, event, handler){
  on(h, event, handler)
}

// Options of [Server.broadcast]: [SendOptions] and except.
// type BroadcastOptions = {mode?: string, except?: Peer}
// [except]: a peer that does not get it (the one who sent the news, say)

// broadcast(name: string, data?: any, options?: BroadcastOptions)
// Queues a message for every connected peer (encoded once).
func server_methods.broadcast(h, name, data, options){
  local mode = mode_of(options)
  local packed = pack(h.proto, name, data)
  local except = options != null and options.except or null
  for(let local peer in values(h.peers)){
    if(peer != except){
      queue_packed(peer.conn, packed, mode)
    }
  }
}

local func reject(h, reason, ip, port){
  send_packet(h, {REJECT, reason}, ip, port)
}

// a new peer, connected; accept(peer) is the ACCEPT packet it is sent
// (again when the client did not hear it)
local func admit(h, ip, port, t, accept, keys){
  local c = new_conn(h, ip, port, t)
  c.state = "connected"
  if(keys != null){
    c.send_key = keys.send
    c.recv_key = keys.recv
  }
  local peer = {
    @meta: peer_meta, id: h.next_id, address: c.address, ip: ip, port: port, server: h, conn: c,
    secure: keys != null,
  }
  h.next_id = h.next_id + 1
  c.peer = peer
  h.by_address[c.address] = c
  h.peers[peer.id] = peer
  c.accept = accept(peer)
  send_packet(h, c.accept, ip, port)
  local handler = h.handlers.connect
  if(handler != null){
    handler(peer)
  }
}

// the cookie of a hello from ip:port at a period: only who gets packets
// at that address can know it
local func cookie_of(h, ip, port, nonce, period){
  return str.substring(crypto.hmac(
    "sha256", h.secure.cookie_key, concat(ip, ":", string(port), "/", string(nonce), "/", string(period)),
  ), 0, 16)
}

// a SECURE packet ({SECURE, MAGIC, signature, nonce, cookie, the client's
// key, proof}): the client proves it knows the server's key and the
// password; the server answers with its key for this connection and
// proof that it is the server
local func secure_connect(h, p, ip, port, t){
  local sec = h.secure
  local signature = h.proto != null and h.proto.signature or ""
  local nonce = p[3]
  local client_public = p[5]
  if(p[1] != MAGIC or p[2] != signature or type(nonce) != "int" or type(p[4]) != "string"
     or type(client_public) != "string" or len(client_public) != 32 or type(p[6]) != "string"){
    return
  }
  local period = to_int(math.floor(t / COOKIE_PERIOD))
  if(not crypto.equal(p[4], cookie_of(h, ip, port, nonce, period))
     and not crypto.equal(p[4], cookie_of(h, ip, port, nonce, period - 1))){
    return
  }
  if(count(h.peers) >= h.max_peers){
    return reject(h, "net: the server is full", ip, port)
  }
  local es = crypto.x25519(sec.secret, client_public)
  if(es == null){
    return
  }
  local th = transcript(signature, nonce, sec.public, client_public)
  local proof_key = hkdf(concat(es, sec.psk), th, "slang/net proof")
  if(crypto.decrypt(CIPHER, proof_key, iv_of(0, 1), p[6], th) != "hello"){
    return reject(h, "net: wrong password", ip, port)
  }
  local mine = crypto.random_bytes(32)
  local mine_public = crypto.x25519(mine)
  local ee = crypto.x25519(mine, client_public)
  if(ee == null){
    return
  }
  local th2 = sha(th, mine_public)
  local ikm = concat(es, ee, sec.psk)
  local keys = {send: hkdf(ikm, th2, "slang/net s2c"), recv: hkdf(ikm, th2, "slang/net c2s")}
  admit(h, ip, port, t, func(peer){
    local confirm = crypto.encrypt(CIPHER, keys.send, iv_of(0, 1), string(peer.id), th2)
    return {ACCEPT, peer.id, nonce, mine_public, confirm}
  }, keys)
  h.by_address[concat(ip, ":", string(port))].nonce = nonce
}

local func server_receive(h, data, ip, port, t){
  local p = try { decode(data) } catch { null }
  if(type(p) != "table"){
    return
  }
  local address = concat(ip, ":", string(port))
  local c = h.by_address[address]
  local kind = p[0]
  local signature = h.proto != null and h.proto.signature or ""
  if(kind == DATA){
    if(c != null){
      on_data(c, p, t)
    }
  } else if(kind == CONNECT){
    if(h.secure != null){
      if(c == null and p[1] == MAGIC){
        reject(h, "net: the server takes only encrypted connections", ip, port)
      }
      return
    }
    if(c != null){
      send_packet(h, c.accept, ip, port)
      return
    }
    if(p[1] != MAGIC){
      return
    }
    if(p[2] != signature){
      return reject(h, "net: the client speaks another protocol", ip, port)
    }
    if(count(h.peers) >= h.max_peers){
      return reject(h, "net: the server is full", ip, port)
    }
    local nonce = p[3]
    admit(h, ip, port, t, func(peer){ return {ACCEPT, peer.id, nonce} }, null)
  } else if(kind == HELLO){
    if(c != null or p[1] != MAGIC or type(p[3]) != "int"){
      return
    }
    if(h.secure == null){
      return reject(h, "net: the server does not encrypt", ip, port)
    }
    if(p[2] != signature){
      return reject(h, "net: the client speaks another protocol", ip, port)
    }
    local period = to_int(math.floor(t / COOKIE_PERIOD))
    send_packet(h, {CHALLENGE, p[3], cookie_of(h, ip, port, p[3], period), h.secure.public}, ip, port)
  } else if(kind == SECURE){
    if(h.secure == null){
      return
    }
    if(c != null){
      // (the client did not hear the accept)
      if(c.nonce == p[3]){
        send_packet(h, c.accept, ip, port)
      }
      return
    }
    secure_connect(h, p, ip, port, t)
  } else if(kind == DISCONNECT){
    if(c != null){
      local reason = goodbye_reason(c, p)
      if(reason != null){
        close_conn(c, reason, false)
      }
    }
  }
}

close_conn = func(c, reason, tell){
  if(c.state == "closed"){
    return
  }
  local h = c.host
  local was = c.state
  c.state = "closed"
  if(tell){
    for(local i = 0; i < GOODBYES; i = i + 1){
      if(c.send_key == null){
        send_packet(h, {DISCONNECT, reason}, c.ip, c.port)
      } else {
        local s = c.seq
        c.seq = s + 1
        send_packet(h, {DISCONNECT, s, crypto.encrypt(CIPHER, c.send_key, iv_of(s, 0), string(reason))}, c.ip, c.port)
      }
    }
  }
  local handler = h.handlers.disconnect
  if(h.is_server){
    delete(h.by_address, c.address)
    delete(h.peers, c.peer.id)
    if(handler != null){
      handler(c.peer, reason)
    }
  } else {
    h.reason = reason
    // a client is done with its socket (its goodbyes are sent first)
    if(not h.closed){
      send_delayed(h, math.inf)
      h.closed = true
      h.udp:close()
    }
    if(handler != null and (was == "connected" or was == "connecting")){
      handler(reason)
    }
  }
}

// poll()
// Handles what arrived (the handlers run), drops clients that timed out
// and sends what is queued. A game calls it once per frame.
func server_methods.poll(h){
  if(h.closed){
    return
  }
  pump()
  local t = now()
  for(let local d in values(take_inbox(h, t))){
    server_receive(h, d[0], d[1], d[2], t)
  }
  for(let local peer in values(h.peers)){
    if(t - peer.conn.last_recv > h.timeout){
      close_conn(peer.conn, "net: timed out", false)
    }
  }
  server_methods.flush(h)
}

// flush()
// Sends what is queued now, without waiting for the next [Server.poll].
func server_methods.flush(h){
  local t = now()
  for(let local peer in values(h.peers)){
    flush(peer.conn, t)
  }
  send_delayed(h, t)
}

// Options of [Server.run] and [Client.run].
// type RunOptions = {rate?: number, tick?: func(dt: number)}
// [rate]: polls per second, 60 by default
// [tick]: runs after each poll with the ms since the one before

local func run(h, options, poll){
  options = options or {}
  local period = 1000 / (options.rate or 60)
  local tick = options.tick
  local timer = uv.timer()
  h.timer = timer
  local last = now()
  timer:start(0, math.max(1, to_int(math.round(period))), func(){
    poll(h)
    if(h.closed){
      timer:close()
      return
    }
    local t = now()
    if(tick != null){
      tick(t - last)
    }
    last = t
  })
  if(not uv.running()){
    uv.run()
  }
}

// run(options?: RunOptions)
// Polls rate times a second until [Server.close], for a server without a
// frame loop of its own. Outside slang/async it runs the event loop and
// returns once the server is closed; inside, it returns at once.
func server_methods.run(h, options){
  run(h, options, server_methods.poll)
}

// close()
// Tells every peer and stops listening; the "disconnect" handler runs for
// each.
func server_methods.close(h){
  if(h.closed){
    return
  }
  for(let local peer in values(h.peers)){
    close_conn(peer.conn, "net: the server closed", true)
  }
  send_delayed(h, math.inf)
  h.closed = true
  h.udp:close()
}

// ------------------------------------------------------------ clients

local client_methods = {}
local client_get = {}

// A connection to a server: [connect] makes one.
// type Client = {id: int?, state: string, reason: string?,
//   on: func(event: string, handler: function?),
//   send: func(name: string, data?: any, options?: SendOptions),
//   poll: func(), flush: func(), run: func(options?: RunOptions), close: func()}
// [state]: "connecting", "connected" or "closed"
// [reason]: why it closed, once it is closed
local client_meta = {__type: "net.Client", __index: client_methods, __get: client_get}

// id(self) -> int?
// The id the server gave this client ([Peer.id] there), once connected.
func client_get.id(cl){
  return cl.peer_id
}

// state(self) -> string
func client_get.state(cl){
  return cl.conn.state
}

// connected(self) -> bool
func client_get.connected(cl){
  return cl.conn.state == "connected"
}

// fingerprint(self) -> string?
// With options.secure, the fingerprint of the key the server answered
// with (once it did): what a player compares with the host's, when it
// was not given.
func client_get.fingerprint(cl){
  return cl.server_fingerprint
}

// rtt(self) -> number
// The round-trip time to the server in ms, smoothed.
func client_get.rtt(cl){
  return cl.conn.rtt
}

// loss(self) -> number
// The part of the packets sent to the server that were lost lately, 0 to 1.
func client_get.loss(cl){
  return cl.conn.loss
}

// Options of [connect].
// type ConnectOptions = {protocol?: Protocol, timeout?: number, simulate?: Simulate,
//   secure?: bool | ClientSecure}
// [protocol]: the server's [Protocol]
// [secure]: connect encrypted (the server must have options.secure)
// [timeout]: ms without a word from the server before giving up (5000)
// [simulate]: a worse network, for testing

// What an encrypting client knows of its server.
// type ClientSecure = {fingerprint?: string, password?: string}
// [fingerprint]: the server's ([Server.fingerprint]); without it any key
//   is taken (encrypted, but whoever answers could be in between); see
//   [Client.fingerprint]
// [password]: the server's

local func send_connect(cl, t){
  local signature = cl.proto != null and cl.proto.signature or ""
  local sec = cl.secure
  local packet = if(sec == null){
    {CONNECT, MAGIC, signature, cl.nonce}
  } else if(sec.answer == null){
    {HELLO, MAGIC, signature, cl.nonce}
  } else {
    {SECURE, MAGIC, signature, cl.nonce, sec.answer.cookie, sec.public, sec.answer.proof}
  }
  send_packet(cl, packet, cl.conn.ip, cl.conn.port)
  cl.last_connect = t
}

local func start_client(cl, ip, port){
  local t = now()
  cl.udp:bind(if(str.contains(ip, ":")){ "::" } else { "0.0.0.0" }, 0)
  listen(cl)
  cl.conn.ip = ip
  cl.conn.port = port
  cl.conn.address = concat(ip, ":", string(port))
  cl.conn.last_recv = t
  send_connect(cl, t)
}

// connect(host: string, port: int, options?: ConnectOptions) -> Client
// A client connecting to a server; host is an IP address or a name to
// look up. Its handlers ([Client.on]) run in [Client.poll]: "connect" with
// nothing once the server accepted it, "disconnect" with the reason (when
// it could not connect too), a message with its data. Messages sent before
// it is connected wait.
func net.connect(host, port, options){
  options = options or {}
  local cl = new_host(options.protocol, options)
  cl.@meta = client_meta
  cl.is_server = false
  cl.nonce = math.random_int(0, 0x7FFF_FFFF)
  local sec = secure_of(options.secure, "{fingerprint?, password?}")
  if(sec != null){
    if(sec.fingerprint != null and type(sec.fingerprint) != "string"){
      raise(error.new(error.kinds.argument, "net: secure.fingerprint is a string"))
    }
    local secret = crypto.random_bytes(32)
    cl.secure = {
      secret: secret, public: crypto.x25519(secret), psk: psk_of(sec.password),
      expect: if(sec.fingerprint == null){ null } else { plain_fingerprint(sec.fingerprint) },
      answer: null,
    }
  }
  cl.conn = new_conn(cl, "", port, now())
  if(host == "localhost"){
    host = "127.0.0.1"
  }
  if(is_ip(host)){
    start_client(cl, host, port)
  } else {
    cl.resolving = true
    uv.getaddrinfo(host, port, "ipv4", func(err, addresses){
      cl.resolving = false
      if(cl.closed or cl.conn.state == "closed"){
        return
      }
      if(err != null or len(addresses) == 0){
        cl.failed = concat("net: cannot find ", host, if(err != null){ concat(": ", err.message) } else { "" })
        return
      }
      start_client(cl, addresses[0].ip, port)
    })
  }
  return cl
}

// on(event: string, handler: function?)
// Sets the handler of an event ("connect", "disconnect") or a message
// name, replacing the one before; null removes it.
func client_methods.on(cl, event, handler){
  on(cl, event, handler)
}

// send(name: string, data?: any, options?: SendOptions)
// Queues a message for the server; it goes out with the next poll (once
// connected).
func client_methods.send(cl, name, data, options){
  if(cl.conn.state == "closed"){
    return
  }
  queue_packed(cl.conn, pack(cl.proto, name, data), mode_of(options))
}

local func client_receive(cl, data, ip, port, t){
  local c = cl.conn
  if(ip != c.ip or port != c.port){
    return
  }
  local p = try { decode(data) } catch { null }
  if(type(p) != "table"){
    return
  }
  local kind = p[0]
  if(kind == DATA){
    if(c.state == "connected"){
      on_data(c, p, t)
    }
  } else if(kind == CHALLENGE){
    local sec = cl.secure
    if(sec == null or c.state != "connecting" or sec.answer != null or p[1] != cl.nonce
       or type(p[2]) != "string" or type(p[3]) != "string" or len(p[3]) != 32){
      return
    }
    local fingerprint = net.fingerprint(p[3])
    if(sec.expect != null and plain_fingerprint(fingerprint) != sec.expect){
      return close_conn(c, concat(
        "net: the server's key is not the one expected (", fingerprint, "): another server, or someone in between",
      ), false)
    }
    local es = crypto.x25519(sec.secret, p[3])
    if(es == null){
      return
    }
    cl.server_fingerprint = fingerprint
    local signature = cl.proto != null and cl.proto.signature or ""
    local th = transcript(signature, cl.nonce, p[3], sec.public)
    local proof_key = hkdf(concat(es, sec.psk), th, "slang/net proof")
    sec.answer = {
      cookie: p[2], th: th, es: es,
      proof: crypto.encrypt(CIPHER, proof_key, iv_of(0, 1), "hello", th),
    }
    send_connect(cl, t)
  } else if(kind == ACCEPT){
    if(c.state == "connecting" and p[2] == cl.nonce and type(p[1]) == "int" and cl.secure != null){
      // the server's key for this connection, and its proof
      local a = cl.secure.answer
      if(a == null or type(p[3]) != "string" or len(p[3]) != 32 or type(p[4]) != "string"){
        return
      }
      local ee = crypto.x25519(cl.secure.secret, p[3])
      if(ee == null){
        return
      }
      local th2 = sha(a.th, p[3])
      local ikm = concat(a.es, ee, cl.secure.psk)
      local recv = hkdf(ikm, th2, "slang/net s2c")
      if(crypto.decrypt(CIPHER, recv, iv_of(0, 1), p[4], th2) != string(p[1])){
        return
      }
      c.send_key = hkdf(ikm, th2, "slang/net c2s")
      c.recv_key = recv
    }
    if(c.state == "connecting" and p[2] == cl.nonce and type(p[1]) == "int"){
      c.state = "connected"
      c.last_recv = t
      cl.peer_id = p[1]
      local handler = cl.handlers.connect
      if(handler != null){
        handler()
      }
    }
  } else if(kind == REJECT){
    if(c.state == "connecting"){
      close_conn(c, text_or(p[1], "net: rejected"), false)
    }
  } else if(kind == DISCONNECT){
    local reason = goodbye_reason(c, p)
    if(reason != null){
      close_conn(c, reason, false)
    }
  }
}

// poll()
// Handles what arrived (the handlers run) and sends what is queued. A game
// calls it once per frame.
func client_methods.poll(cl){
  if(cl.closed){
    return
  }
  pump()
  local c = cl.conn
  local t = now()
  if(cl.failed != null){
    close_conn(c, cl.failed, false)
    cl.failed = null
  }
  for(let local d in values(take_inbox(cl, t))){
    client_receive(cl, d[0], d[1], d[2], t)
  }
  if(c.state == "connecting" and not cl.resolving){
    if(t - c.last_recv > cl.timeout){
      close_conn(c, "net: cannot connect: no answer", false)
    } else if(t - cl.last_connect >= CONNECT_RETRY){
      send_connect(cl, t)
    }
  } else if(c.state == "connected" and t - c.last_recv > cl.timeout){
    close_conn(c, "net: timed out", false)
  }
  client_methods.flush(cl)
}

// flush()
// Sends what is queued now, without waiting for the next [Client.poll].
func client_methods.flush(cl){
  local t = now()
  flush(cl.conn, t)
  send_delayed(cl, t)
}

// run(options?: RunOptions)
// Polls rate times a second until [Client.close] (a bot, a test). Outside
// slang/async it runs the event loop and returns once the client is
// closed; inside, it returns at once.
func client_methods.run(cl, options){
  run(cl, options, client_methods.poll)
}

// close()
// Tells the server (when connected) and closes the socket; the
// "disconnect" handler runs.
func client_methods.close(cl){
  if(cl.closed){
    return
  }
  close_conn(cl.conn, "net: the client closed", cl.conn.state == "connected")
}

return net
