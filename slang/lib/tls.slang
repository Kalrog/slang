// slang/tls: TLS on libuv TCP, with the tls native extension (OpenSSL).
//
//   local tls = require("slang/tls")
//   local conn = async.await(tls.connect("example.com", 443))
//   async.await(async.write(conn, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
//
// A [Connection] works like the uv.tcp handle it wraps (read_start(cb),
// read_stop(), write(data, cb), shutdown(cb), close(cb), getsockname(),
// getpeername(), nodelay, keepalive, ...), so slang/async's reader, write
// and close, and slang/http and slang/ws on top of them, use it as they
// are. Writes made during the handshake wait for it; a failed handshake (a
// certificate that does not verify, say) reaches them and the reader as
// the error.
//
// A client verifies the server's certificate against the system's trust
// store and the host name by default; verify: false turns that off. A
// server needs a context with server: true, cert and key (see [context]).

// The options of [context]: the tls extension's context options, or files
// to read the PEM text from. A verifying client needs the server's
// certificate valid for the host name; a verifying server asks the client
// for a certificate.
// type ContextOptions = {server?: bool, cert?: string, key?: string,
//   ca?: string, verify?: bool, alpn?: {string}, min_version?: string,
//   cert_file?: string, key_file?: string, ca_file?: string}
// [cert_file]: a file to read cert from
// [key_file]: a file to read key from
// [ca_file]: a file to read ca from
// [server]: a server context (false by default)
// [cert]: PEM text of the certificate chain, leaf first; needed by a server
// [key]: PEM text of the certificate's private key; needed by a server
// [ca]: PEM text of the certificates to trust instead of the system's
// [verify]: check the peer's certificate (a client does by default)
// [alpn]: protocol names to offer or accept, by preference
// [min_version]: "1.2" (the default) or "1.3"

// A context of the tls extension: settings shared by many connections
// (certificates, trust, ALPN), made by [context].
// type Context

// What [Connection.info] tells about a connection; fields not known yet
// are null.
// type Info = {version: string, cipher?: string, alpn?: string,
//   peer?: string, server_name?: string}
// [version]: the protocol version ("TLSv1.3")
// [alpn]: the protocol chosen with ALPN
// [peer]: the subject of the peer's certificate
// [server_name]: the host name the client asked for

// A certificate and its key as PEM text, from [self_signed].
// type Certificate = {cert: string, key: string}

// The options of [connect]: a context's options, or a context made
// before, and the name to verify.
// type ConnectOptions = {context?: Context, server_name?: string,
//   ca?: string, ca_file?: string, cert?: string, cert_file?: string,
//   verify?: bool, alpn?: {string}, min_version?: string}
// [context]: a context to use instead of one made from the options
// [server_name]: the name to ask for and verify (the host by default)

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

// [c] is the native extension under this module (OpenSSL's engine:
// context, session, self_signed), loaded when first used.
tls.@meta = {
  __index: func(t, key){
    if(key == "c"){
      return engine()
    }
    return null
  },
}

// context(options?: ContextOptions) -> Context
// A context for many connections: the tls extension's context, with
// cert_file, key_file and ca_file read into PEM text first.
//
//   local ctx = tls.context({server: true, cert_file: "cert.pem",
//     key_file: "key.pem", alpn: {"http/1.1"}})
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

// self_signed(names: {string}, days?: int) -> Certificate
// A certificate for local development, valid for days (365), with an EC
// P-256 key.
// [names]: host names or IP addresses; the first is the subject
func tls.self_signed(names, days){
  return engine().self_signed(names, days)
}

// ------------------------------------------------------------ connections

local methods = {}
local getters = {}

// A TLS connection over a uv.tcp handle; type(conn) is "tls.Connection".
// It also has the handle's getsockname, getpeername, nodelay, keepalive,
// is_closing, is_active, fileno, ref, unref and has_ref, which go to the
// TCP handle.
// type Connection
local connection_meta = {
  __type: "tls.Connection", __index: methods, __get: getters
}

// info(self) -> Info
// The protocol version, cipher, ALPN protocol, peer and server name.
func getters.info(t){
  return t.session:info()
}

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
    eof_told: false, pending: {}, waiting: {}
  }
  t.tcp_cb = func(err, chunk){ on_tcp(t, err, chunk) }
  t.@meta = connection_meta
  return t
}

local client_context = null

// client(tcp, options?: {server_name?: string, context?: Context})
//   -> Connection
// A client connection over a connected uv.tcp handle; its handshake starts
// at once. client(tcp, server_name, context) works too.
// [server_name]: the name to ask for and verify (needed when verifying)
// [context]: a shared default client context when null
func tls.client(tcp, server_name, context){
  if(type(server_name) == "table"){
    context = server_name.context
    server_name = server_name.server_name
  }
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

// server(tcp, context: Context) -> Connection
// A server connection over an accepted uv.tcp handle; the handshake runs
// as the client's bytes arrive.
func tls.server(tcp, context){
  local t = connection(tcp, context:session())
  start_reading(t)
  return t
}

// connect(host: string, port: int, options?: ConnectOptions) -> async.Future
// Connects over TCP and completes the handshake: a Future of the
// [Connection]. It fails, with the TCP handle closed, when connecting or
// the handshake fails.
func tls.connect(host, port, options){
  options = options or {}
  return async.run(func(){
    local context = options.context
    local own = false
    for(let local name in values({
      "ca", "ca_file", "cert", "cert_file", "key", "key_file", "verify", "alpn",
      "min_version"
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

// handshake() -> async.Future
// A Future of the connection once the handshake is done (at once when it
// is); it fails with the handshake's error.
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

// read_start(cb: func(err: any, chunk: string?))
// Calls cb with each chunk of plaintext as it arrives, and with a null
// chunk at the end of the stream; cb(err, null) when the connection fails.
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

// read_stop()
// Stops calling the reader; plaintext that arrives meanwhile is kept for
// the next one.
func methods.read_stop(t){
  t.on_chunk = null
  if(t.done and t.reading){
    t.reading = false
    t.tcp:read_stop()
  }
}

// write(data: string, cb?: func(err: any))
// Encrypts and sends data; cb(err) once it is written. Writes made during
// the handshake are sent after it.
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

// shutdown(cb?: func(err: any))
// Sends a close_notify, then closes the TCP write side.
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

// close(cb?: function)
// Closes the TCP handle; waiting writes and handshakes fail with
// "tls: the connection is closed".
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
  "is_active", "fileno", "ref", "unref", "has_ref"
})){
  // the TCP handle's method of that name
  methods[name] = func(t, ...arguments){
    local tcp = t.tcp
    return tcp[name](tcp, ...arguments)
  }
}

return tls
