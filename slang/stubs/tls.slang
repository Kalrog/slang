// tls: the native binding of OpenSSL 3's TLS (libssl) as an engine on
// memory buffers. It does no I/O: slang/tls moves the bytes between the
// engine and a libuv TCP handle, and most code should use slang/tls.
//
//   local tls = require("tls")
//   local ctx = tls.context({alpn: {"http/1.1"}})
//   local s = ctx:session("example.com")
//   s:handshake()          // false: it waits for the server
//   local out = s:take()   // bytes to send to the server
//
// The system's trust store is OpenSSL's default (SSL_CERT_FILE and
// SSL_CERT_DIR override it), or else the first bundle found at the usual
// paths. Errors read "tls: ...".
local m = {}

local context_methods = {}
local context_meta = {__index: context_methods, __type: "tls.context"}

local session_methods = {}
local session_meta = {__index: session_methods, __type: "tls.session"}

// ------------------------------------------------------------ contexts

// context([options]) -> a tls.context. options:
// server: a server context (false by default);
// cert, key: PEM text of the certificate chain (leaf first) and its
// private key, needed by a server;
// ca: PEM text of the certificates to trust instead of the system's;
// verify: check the peer's certificate; true by default for a client
// (which needs it valid for the host name), a server with verify asks for
// a client certificate;
// alpn: a list of protocol names, by preference;
// min_version: "1.2" (the default) or "1.3".
func m.context(options){ return {meta: context_meta} }

// ctx:session([hostname]) -> a tls.session: a client for hostname (a host
// name or an IP address; needed when the context verifies), or a server
// for a server context
func context_methods.session(ctx, hostname){ return {meta: session_meta} }

// ------------------------------------------------------------ sessions

// session:feed(bytes) hands the session bytes that arrived from the network
func session_methods.feed(session, bytes){}

// session:handshake() -> true when the handshake is done, false while it
// waits for the peer; raises when it fails (a certificate that does not
// verify, for one)
func session_methods.handshake(session){}

// session:read() -> the plaintext decrypted so far ("" for none), or null
// once the peer closed the session (close_notify)
func session_methods.read(session){}

// session:write(plaintext) encrypts plaintext for take(); only after the
// handshake
func session_methods.write(session, plaintext){}

// session:take() -> the bytes to send to the network ("" for none); call
// it after every other method, which may all produce some
func session_methods.take(session){}

// session:close() queues a close_notify for take(), when the handshake got
// that far
func session_methods.close(session){}

// session:info() -> {version, cipher, alpn, peer, server_name}: the
// protocol version, the cipher, the protocol chosen with ALPN, the subject
// of the peer's certificate and the host name the client asked for (the
// last three only when known)
func session_methods.info(session){}

// ------------------------------------------------------------ certificates

// self_signed(names, [days]) -> {cert, key} as PEM text: a certificate for
// local development, valid for days (365), with an EC P-256 key. names are
// host names or IP addresses; the first is the subject.
func m.self_signed(names, days){}

// version() -> the OpenSSL version text
func m.version(){}

return m
