// slang/tls: TLS on libuv TCP, with the tls native extension (OpenSSL).
//
//   local tls = require("slang/tls")
//   local conn = async.await(tls.connect("example.com", 443))
//
//   tls.connect(host, port, options) -> Future of a connection whose
//     handshake completed; options are a context's (below), or context
//     (one made before), and server_name (the name to verify, the host by
//     default)
//   tls.client(tcp, server_name, context) -> a connection over a connected
//     uv.tcp handle; its handshake starts at once
//   tls.server(tcp, context) -> a connection over an accepted uv.tcp handle;
//     the handshake runs as the client's bytes arrive
//   tls.context(options) -> a context for many connections: the tls
//     extension's options (server, cert, key, ca as PEM text, verify, alpn,
//     min_version), or cert_file, key_file and ca_file to read them from
//   tls.self_signed(names, [days]) -> {cert, key} for local development
//
// A connection works like the uv.tcp handle it wraps (read_start(cb),
// read_stop(), write(data, cb), shutdown(cb), close(cb), getsockname(),
// getpeername(), ...), so slang/async's reader, write and close, and
// slang/http and slang/ws on top of them, use it as they are. Writes made
// during the handshake wait for it; a failed handshake (a certificate that
// does not verify, say) reaches them and the reader as the error. Also:
//   conn:handshake() -> Future of the connection once the handshake is done
//   conn:info() -> {version, cipher, alpn, peer, server_name}
// A client verifies the server's certificate against the system's trust
// store and the host name by default; verify: false turns that off.
local async = require("slang/async")
local os = require("slang/os")

local tls = {}

local native = null
local func engine(){
  if(native == null){
    native = require("tls")
  }
  return native
}

// context(options): files read into PEM text, then the extension's context
func tls.context(options){
  local o = {}
  for(let local e in entries(options or {})){
    o[e[0]] = e[1]
  }
  for(let local name in values({"cert", "key", "ca"})){
    local file = o[concat(name, "_file")]
    if(file != null){
      o[name] = os.read_file(file)
    }
  }
  return engine().context(o)
}

func tls.self_signed(names, days){
  return engine().self_signed(names, days)
}

// ------------------------------------------------------------ connections

local methods = {}
local meta = {__index: methods, __type: "TlsConnection"}

// sends what the engine has for the network; cb(err) once it is written
local func flush(t, cb){
  local out = t.session:take()
  if(len(out) > 0 and not t.closed){
    t.tcp:write(out, cb)
  } else if(cb != null){
    cb(null)
  }
}

// the handshake or the connection failed: every waiter hears it
local func fail(t, err){
  if(t.error == null){
    t.error = err
  }
  if(t.reading){
    t.reading = false
    t.tcp:read_stop()
  }
  local waiting = t.waiting
  local pending = t.pending
  t.waiting = {}
  t.pending = {}
  for(let local w in values(waiting)){
    w(t.error)
  }
  for(let local p in values(pending)){
    if(p.cb != null){
      p.cb(t.error)
    }
  }
  if(t.on_chunk != null){
    t.on_chunk(t.error, null)
  }
}

// hands the plaintext received so far to the reader, while there is one
local func deliver(t){
  for(t.on_chunk != null and t.at < len(t.received)){
    local chunk = t.received[t.at]
    t.received[t.at] = null
    t.at = t.at + 1
    t.on_chunk(null, chunk)
  }
  if(t.at >= len(t.received)){
    t.received = {}
    t.at = 0
  }
  if(t.on_chunk != null and t.eof and not t.eof_told){
    t.eof_told = true
    t.on_chunk(null, null)
  }
}

// the handshake is done: the writes it held go out, its waiters go on
local func established(t){
  t.done = true
  local pending = t.pending
  t.pending = {}
  for(let local p in values(pending)){
    t.session:write(p.data)
    flush(t, p.cb)
  }
  local waiting = t.waiting
  t.waiting = {}
  for(let local w in values(waiting)){
    w(null)
  }
}

// bytes from the network through the engine: the plaintext ("" for none),
// or null when the peer closed the session
local func advance(t, chunk){
  t.session:feed(chunk)
  if(not t.done){
    if(not t.session:handshake()){
      flush(t, null)
      return ""
    }
    flush(t, null)
    established(t)
  }
  local text = t.session:read()
  flush(t, null)
  return text
}

local func on_tcp(t, err, chunk){
  if(t.error != null){
    return
  }
  if(err != null){
    fail(t, err)
    return
  }
  if(chunk == null){
    if(not t.done){
      fail(t, "tls: the connection closed during the handshake")
      return
    }
    t.eof = true
    deliver(t)
    return
  }
  local r = pcall(advance, t, chunk)
  if(r[0] == "err"){
    fail(t, r[1])
    return
  }
  if(r[1] == null){
    t.eof = true
  } else if(len(r[1]) > 0){
    append(t.received, r[1])
  }
  deliver(t)
  // past the handshake the network is read only for a reader
  if(t.done and t.on_chunk == null and t.reading){
    t.reading = false
    t.tcp:read_stop()
  }
}

local func start_reading(t){
  if(not t.reading and not t.eof and not t.closed){
    t.reading = true
    t.tcp:read_start(t.tcp_cb)
  }
}

local func connection(tcp, session){
  local t = {
    tcp: tcp, session: session, done: false, error: null, closed: false,
    reading: false, on_chunk: null, received: {}, at: 0, eof: false,
    eof_told: false, pending: {}, waiting: {},
  }
  t.tcp_cb = func(err, chunk){ on_tcp(t, err, chunk) }
  t.meta = meta
  return t
}

local client_context = null

// client(tcp, server_name, context): the handshake starts now
func tls.client(tcp, server_name, context){
  if(context == null){
    if(client_context == null){
      client_context = engine().context({})
    }
    context = client_context
  }
  local t = connection(tcp, context:session(server_name))
  t.session:handshake()
  flush(t, null)
  start_reading(t)
  return t
}

func tls.server(tcp, context){
  local t = connection(tcp, context:session())
  start_reading(t)
  return t
}

// connect(host, port, options) -> Future of a connection after its handshake
func tls.connect(host, port, options){
  options = options or {}
  return async.run(func(){
    local context = options.context
    local own = false
    for(let local name in values({
      "ca", "ca_file", "cert", "cert_file", "verify", "alpn", "min_version",
    })){
      own = own or options[name] != null
    }
    if(context == null and own){
      context = tls.context(options)
    }
    local tcp = async.await(async.connect(host, port))
    local r = pcall(func(){
      local t = tls.client(tcp, options.server_name or host, context)
      return async.await(t:handshake())
    })
    if(r[0] == "err"){
      pcall(func(){ tcp:close() })
      raise(r[1])
    }
    return r[1]
  })
}

func methods.handshake(t){
  return async.wrap(func(cb){
    if(t.error != null){
      cb(t.error, null)
    } else if(t.done){
      cb(null, t)
    } else {
      append(t.waiting, func(err){ cb(err, t) })
    }
  })
}

func methods.info(t){
  return t.session:info()
}

func methods.read_start(t, cb){
  t.on_chunk = cb
  if(t.error != null){
    cb(t.error, null)
    return
  }
  deliver(t)
  if(t.on_chunk != null){
    start_reading(t)
  }
}

func methods.read_stop(t){
  t.on_chunk = null
  if(t.done and t.reading){
    t.reading = false
    t.tcp:read_stop()
  }
}

func methods.write(t, data, cb){
  if(t.error != null){
    if(cb != null){
      cb(t.error)
    }
    return
  }
  if(not t.done){
    append(t.pending, {data: data, cb: cb})
    return
  }
  local r = pcall(func(){ t.session:write(data) })
  if(r[0] == "err"){
    if(cb != null){
      cb(r[1])
    }
    return
  }
  flush(t, cb)
}

// shutdown(cb): a close_notify, then the TCP write side closes
func methods.shutdown(t, cb){
  t.session:close()
  flush(t, func(err){
    if(err != null){
      if(cb != null){
        cb(err)
      }
      return
    }
    t.tcp:shutdown(cb)
  })
}

func methods.close(t, cb){
  t.closed = true
  t.reading = false
  if(t.error == null){
    t.error = "tls: the connection is closed"
    local on_chunk = t.on_chunk
    t.on_chunk = null
    fail(t, t.error)
    t.on_chunk = on_chunk
  }
  t.tcp:close(cb)
}

for(let local name in values({
  "getsockname", "getpeername", "nodelay", "keepalive", "is_closing",
  "is_active", "fileno", "ref", "unref", "has_ref",
})){
  methods[name] = func(t, ...arguments){
    local tcp = t.tcp
    return tcp[name](tcp, ...arguments)
  }
}

return tls
