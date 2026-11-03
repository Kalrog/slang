// slang/ws: WebSockets (RFC 6455) on slang/async, both sides.
//
//   local async = require("slang/async")
//   local ws = require("slang/ws")
//   async.main(func(){
//     local socket = async.await(ws.connect("ws://127.0.0.1:8080/live"))
//     async.await(socket:send("hello"))
//     local m = async.await(socket.messages:next())
//     if(not m.done){ print(m.value, "\n") }
//     async.await(socket:close())
//   })
//
// [connect] is the client side; [accept] the server side, for slang/http's
// on_upgrade (slang/web's app:ws does it for you). Either gives a
// [WebSocket]: read its messages Stream, send with [WebSocket.send].
//
// Text messages must be UTF-8 (else the socket closes with 1007); a
// message over max_message closes it with 1009. The server requires masked
// frames and the client sends them; pings are answered; extensions such as
// compression are not negotiated.
local async = require("slang/async")
local str = require("slang/string")
local encoding = require("slang/encoding")
local utf8 = require("slang/utf8")

local ws = {}

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local func crypto(){
  return require("slang/crypto")
}

local func accept_key(key){
  return encoding.base64.encode(crypto().hash("sha1", concat(key, GUID)))
}

local func header_has(value, token){
  for(let local part in values(str.split(str.lower(value or ""), ","))){
    if(str.trim(part) == token){
      return true
    }
  }
  return false
}

// is_upgrade(req: table) -> bool
// Whether a slang/http request asks to upgrade to a WebSocket (its Upgrade
// and Connection headers say so).
func ws.is_upgrade(req){
  return header_has(req.headers["upgrade"], "websocket") and
    header_has(req.headers["connection"], "upgrade")
}

// ------------------------------------------------------------ frames

local OP_CONTINUATION = 0
local OP_TEXT = 1
local OP_BINARY = 2
local OP_CLOSE = 8
local OP_PING = 9
local OP_PONG = 10

// the bytes of n as a big-endian number of size bytes
local func be(n, size){
  local bytes = {}
  for(local i = size - 1; i >= 0; i = i - 1){
    append(bytes, (n >> (8 * i)) & 255)
  }
  return str.from_bytes(bytes)
}

// a frame: fin set; masked with a random key when mask is true (the client)
local func frame(opcode, payload, mask){
  local n = len(payload)
  local head = {128 | opcode}
  local mask_bit = mask and 128 or 0
  local ext = ""
  if(n < 126){
    append(head, mask_bit | n)
  } else if(n < 65536){
    append(head, mask_bit | 126)
    ext = be(n, 2)
  } else {
    append(head, mask_bit | 127)
    ext = be(n, 8)
  }
  if(mask){
    local key = crypto().random_bytes(4)
    return concat(str.from_bytes(head), ext, key, str.xor(payload, key))
  }
  return concat(str.from_bytes(head), ext, payload)
}

local func close_payload(code, reason){
  if(code == null){
    return ""
  }
  return concat(be(code, 2), reason or "")
}

// ------------------------------------------------------------ sockets

local socket_methods = {}
local socket_get = {}

// An open WebSocket connection. Its fields: messages, an async.Stream of
// the messages received (strings, text and binary alike) that ends when
// the connection does; closed, an async.Future of the [CloseInfo] once the
// connection is gone. A program may set on_pong, a function called with
// the data of each pong (see [WebSocket.ping]).
// type WebSocket
local socket_meta = {
  __type: "ws.Socket", __index: socket_methods, __get: socket_get
}

// open(self) -> bool
// Whether messages can still be sent: false once a close has begun.
func socket_get.open(s){
  return s.state == "open"
}

// How a connection ended: the close code the other side sent (1005 when
// none; 1006 when the connection dropped) or the one it was closed with.
// type CloseInfo = {code: int, reason: string}

// Options of [accept] and [connect].
// type Options = {max_message?: int, tls?: bool | table}
// [max_message]: the largest message in bytes (16 MiB); a larger one closes with 1009
// [tls]: connect only: wss, true or slang/tls's connect options

local func new_socket(conn, rest, client, options){
  options = options or {}
  local c = async.controller(null)
  local closed = async.completer()
  local s = {
    @meta: socket_meta, conn: conn, client: client, messages: c.stream,
    closed: closed.future, state: "open",
    max_message: options.max_message or 16 * 1024 * 1024
  }

  local func write(data){
    return async.write(conn, data)
  }

  // ends everything once: the stream, the closed future, the connection
  local func finish(code, reason){
    if(s.state == "gone"){
      return
    }
    s.state = "gone"
    c.close()
    pcall(func(){ conn:close() })
    closed.complete({code: code, reason: reason or ""})
  }
  s.finish = finish

  // fails the connection: a close frame with code, then the end
  local func fail(code, reason){
    if(s.state == "open"){
      s.state = "closing"
      write(frame(OP_CLOSE, close_payload(code, reason), client)):then(
        func(_){
          finish(code, reason)
        },
        func(_){
          finish(code, reason)
        },
      )
    } else {
      finish(code, reason)
    }
  }

  // backpressure: past the stream's high-water mark, reading stops
  local paused = null
  c.on_pause = func(){ paused = async.completer() }
  c.on_resume = func(){
    local p = paused
    paused = null
    if(p != null){ p.complete(null) }
  }

  async.run(func(){
    local reader = async.reader(conn)
    local buf = rest or ""
    local at = 0
    local parts = null
    local part_op = 0
    local size = 0
    local r = pcall(func(){
      for(s.state != "gone"){
        // a whole frame in buf[at..]? else read more
        local avail = len(buf) - at
        local need = 2
        local length = 0
        local masked = false
        local header = 0
        if(avail >= 2){
          local b1 = str.byte_at(buf, at + 1)
          masked = (b1 & 128) != 0
          length = b1 & 127
          header = 2
          if(length == 126){
            header = 4
          } else if(length == 127){
            header = 10
          }
          if(masked){
            header = header + 4
          }
          need = header
          if(avail >= header){
            if(length == 126){
              length = (str.byte_at(buf, at + 2) << 8) |
                str.byte_at(buf, at + 3)
            } else if(length == 127){
              length = 0
              for(local i = 0; i < 8; i = i + 1){
                length = (length << 8) | str.byte_at(buf, at + 2 + i)
              }
              if(length < 0){
                fail(1002, "frame too long")
                return null
              }
            }
            need = header + length
          }
        }
        if(avail < need){
          if(paused != null){
            async.await(paused.future)
          }
          local e = async.await(reader:next())
          if(e.done){
            finish(1006, "the connection closed")
            return null
          }
          if(at > 0){
            buf = str.substring(buf, at)
            at = 0
          }
          buf = concat(buf, e.value)
          if(length > s.max_message + 16){
            fail(1009, "message too big")
            return null
          }
        } else {
          local b0 = str.byte_at(buf, at)
          local fin = (b0 & 128) != 0
          local op = b0 & 15
          if((b0 & 112) != 0){
            fail(1002, "reserved bits set")
            return null
          }
          if(masked == client){
            fail(
              1002,
              client and "a masked frame from the server" or
                "an unmasked frame from the client",
            )
            return null
          }
          local payload = str.substring(buf, at + header, at + header + length)
          if(masked){
            payload = str.xor(
              payload,
              str.substring(buf, at + header - 4, at + header),
            )
          }
          at = at + header + length
          if(op >= 8){
            if(not fin or length > 125){
              fail(1002, "a fragmented or long control frame")
              return null
            }
            if(op == OP_PING){
              if(s.state == "open"){
                write(frame(OP_PONG, payload, client))
              }
            } else if(op == OP_CLOSE){
              local code = 1005
              local reason = ""
              if(len(payload) >= 2){
                code = (str.byte_at(payload, 0) << 8) | str.byte_at(payload, 1)
                reason = str.substring(payload, 2)
              }
              if(s.state == "open"){
                // answer the close, then end
                s.state = "closing"
                local answer = code == 1005 and "" or close_payload(code, "")
                pcall(async.await, write(frame(OP_CLOSE, answer, client)))
              }
              finish(code, reason)
              return null
            } else if(op == OP_PONG){
              if(s.on_pong != null){
                pcall(s.on_pong, payload)
              }
            } else {
              fail(1002, "unknown control opcode")
              return null
            }
          } else {
            if(op == OP_CONTINUATION){
              if(parts == null){
                fail(1002, "a continuation without a start")
                return null
              }
            } else if(op == OP_TEXT or op == OP_BINARY){
              if(parts != null){
                fail(1002, "a new message inside a fragmented one")
                return null
              }
              parts = {}
              part_op = op
              size = 0
            } else {
              fail(1002, "unknown opcode")
              return null
            }
            size = size + len(payload)
            if(size > s.max_message){
              fail(1009, "message too big")
              return null
            }
            append(parts, payload)
            if(fin){
              local message = str.join(parts, "")
              parts = null
              if(part_op == OP_TEXT and not utf8.valid(message)){
                fail(1007, "text that is not UTF-8")
                return null
              }
              if(s.state == "open"){
                c.add(message)
              }
            }
          }
        }
      }
    })
    if(r[0] == "err"){
      local e = r[1]
      finish(1006, type(e) == "table" and e.message or string(e))
    }
  })
  return s
}

local func send_frame(s, opcode, data){
  if(s.state != "open"){
    return async.failed("ws: the socket is not open")
  }
  return async.write(s.conn, frame(opcode, data, s.client))
}

// send(text: string) -> async.Future
// Sends a text message; completes when it is written. Fails when the
// socket is not open.
func socket_methods.send(s, text){
  return send_frame(s, OP_TEXT, text)
}

// send_binary(data: string) -> async.Future
// Sends a binary message, as [WebSocket.send] does.
func socket_methods.send_binary(s, data){
  return send_frame(s, OP_BINARY, data)
}

// ping(data?: string) -> async.Future
// Sends a ping (with up to 125 bytes of data); completes when it is
// written. The pong that answers it goes to socket.on_pong(data), when
// the socket has one.
func socket_methods.ping(s, data){
  return send_frame(s, OP_PING, data or "")
}

// close(code?: int, reason?: string) -> async.Future
// Closes the connection: sends a close frame (code 1000 by default) and
// waits, two seconds at most, for the other side's answer. Gives the
// closed Future, a Future of the [CloseInfo]; once closing, it only
// returns that.
func socket_methods.close(s, code, reason){
  if(s.state == "open"){
    s.state = "closing"
    code = code or 1000
    async.write(s.conn, frame(OP_CLOSE, close_payload(code, reason), s.client))
    local timer = require("uv").timer()
    timer:start(2000, 0, func(){
      timer:close()
      s.finish(code, reason)
    })
    s.closed:then(func(_){
      if(not timer:is_closing()){
        timer:stop()
        timer:close()
      }
    })
  }
  return s.closed
}

// ------------------------------------------------------------ handshakes

// accept(req: table, conn, rest: string, options?: Options) -> WebSocket
// Completes the handshake of an upgrade request and gives the server side
// of the WebSocket. A request that is not a WebSocket handshake (GET,
// version 13, with a key) gets a 400 and accept raises.
// [req]: the slang/http request
// [conn]: the connection on_upgrade handed over
// [rest]: the bytes read past the request head
func ws.accept(req, conn, rest, options){
  local key = req.headers["sec-websocket-key"]
  if(not ws.is_upgrade(req) or key == null or
    req.headers["sec-websocket-version"] != "13" or req.method != "GET"){
    require("slang/http").write_response(conn, req, {
      status: 400,
      body: "a WebSocket handshake was expected\n",
      headers: {["Sec-WebSocket-Version"]: "13"},
    })
    error("ws: not a WebSocket handshake")
  }
  async.write(conn, concat(
    "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n",
    "Sec-WebSocket-Accept: ",
    accept_key(key),
    "\r\n\r\n",
  ))
  return new_socket(conn, rest, false, options)
}

// host, port and path of a ws:// or wss:// URL, and whether it is wss
local func split_url(url){
  local secure = str.starts_with(url, "wss://")
  if(not secure and not str.starts_with(url, "ws://")){
    error("ws.connect: a ws:// or wss:// URL expected: ", url)
  }
  local rest = str.substring(url, secure and 6 or 5)
  local slash = str.index_of(rest, "/")
  local authority = slash >= 0 and str.substring(rest, 0, slash) or rest
  local path = slash >= 0 and str.substring(rest, slash) or "/"
  local host = authority
  local port = secure and 443 or 80
  local port_text = null
  if(str.starts_with(authority, "[")){
    local close = str.index_of(authority, "]")
    if(close < 0){
      error("ws.connect: a ] expected in ", url)
    }
    host = str.substring(authority, 1, close)
    if(str.starts_with(authority, ":", close + 1)){
      port_text = str.substring(authority, close + 2)
    }
  } else {
    local colon = str.index_of(authority, ":")
    if(colon >= 0){
      host = str.substring(authority, 0, colon)
      port_text = str.substring(authority, colon + 1)
    }
  }
  if(port_text != null){
    port = to_int(port_text)
    if(port == null){
      error("ws.connect: a bad port in ", url)
    }
  }
  return {host: host, port: port, path: path, secure: secure}
}

// connect(url: string, options?: Options) -> async.Future
// Opens a WebSocket to a ws:// or wss:// URL: a Future of the client side
// [WebSocket]; wss uses TLS (options.tls adds slang/tls's connect
// options). It fails when the server does not accept the handshake.
// connect(host, port, path?, options?) works too.
func ws.connect(host, port, path, options){
  if(type(port) != "int"){
    local u = split_url(host)
    local o = {}
    for(let local e in entries(port or {})){
      o[e[0]] = e[1]
    }
    if(u.secure and (o.tls == null or o.tls == false)){
      o.tls = true
    }
    host = u.host
    port = u.port
    path = u.path
    options = o
  }
  return async.run(func(){
    local conn = null
    local secure = options != null and options.tls != null and
      options.tls != false
    if(secure){
      local o = options.tls
      if(o == true){
        o = {}
      }
      conn = async.await(require("slang/tls").connect(host, port, o))
    } else {
      conn = async.await(async.connect(host, port))
    }
    local key = encoding.base64.encode(crypto().random_bytes(16))
    // the port only when it is not the scheme's; an IPv6 address in brackets
    local authority = str.index_of(host, ":") >= 0 and concat("[", host, "]") or
      host
    if(port != (secure and 443 or 80)){
      authority = concat(authority, ":", string(port))
    }
    async.await(async.write(conn, concat(
      "GET ", path or "/", " HTTP/1.1\r\nHost: ", authority,
      "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ",
      key, "\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )))
    local p = require("llhttp").parser("response", null)
    local reader = async.reader(conn)
    local head = null
    local rest = null
    for(rest == null){
      local e = async.await(reader:next())
      if(e.done){
        error("ws: the server closed the connection during the handshake")
      }
      for(let local ev in values(p:execute(e.value))){
        if(ev.type == "head"){
          head = ev
        } else if(ev.type == "upgrade"){
          rest = ev.rest
        } else if(ev.type == "error"){
          error("ws: a malformed handshake answer: ", ev.reason)
        } else if(ev.type == "done" and head != null and head.status != 101){
          conn:close()
          error(
            "ws: the server answered ", string(head.status), " instead of 101"
          )
        }
      }
    }
    if(head.status != 101 or
      head.headers["sec-websocket-accept"] != accept_key(key)){
      conn:close()
      error("ws: the server did not accept the WebSocket handshake")
    }
    // the reader has done its part; frames are read by the socket, starting
    // with whatever the reader already holds
    conn:read_stop()
    for(let local chunk in values(reader.buffer)){
      rest = concat(rest, chunk)
    }
    reader.buffer = {}
    return new_socket(conn, rest, true, options)
  })
}

return ws
