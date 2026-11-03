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

// The options of [context]. A verifying client needs the server's
// certificate valid for the host name; a verifying server asks the client
// for a certificate.
// type ContextOptions = {server?: bool, cert?: string, key?: string,
//   ca?: string, verify?: bool, alpn?: {string}, min_version?: string}
// [server]: a server context (false by default)
// [cert]: PEM text of the certificate chain, leaf first; needed by a server
// [key]: PEM text of the certificate's private key; needed by a server
// [ca]: PEM text of the certificates to trust instead of the system's
// [verify]: check the peer's certificate (a client does by default)
// [alpn]: protocol names to offer or accept, by preference
// [min_version]: "1.2" (the default) or "1.3"

// What [Session.info] tells about a session.
// type Info = {version: string, cipher?: string, alpn?: string,
//   peer?: string, server_name?: string}
// [version]: the protocol version ("TLSv1.3")
// [alpn]: the protocol chosen with ALPN
// [peer]: the subject of the peer's certificate
// [server_name]: the host name the client asked for

// A certificate and its key as PEM text, from [self_signed].
// type Certificate = {cert: string, key: string}

// Settings shared by many sessions: certificates, trust, ALPN.
// type Context
local context_methods = {}
local context_meta = {__index: context_methods, __type: "tls.context"}

// One TLS connection's state machine: bytes from the network go in with
// [Session.feed], bytes for the network come out of [Session.take].
// type Session
local session_methods = {}
local session_meta = {__index: session_methods, __type: "tls.session"}

// ------------------------------------------------------------ contexts

// context(options?: ContextOptions) -> Context
// A context; raises "tls: ..." for a certificate or key it cannot load.
func m.context(options){ return {@meta: context_meta} }

// session(hostname?: string) -> Session
// A client session for hostname (a host name or an IP address; needed when
// the context verifies), or a server session for a server context.
func context_methods.session(ctx, hostname){ return {@meta: session_meta} }

// ------------------------------------------------------------ sessions

// feed(bytes: string)
// Hands the session bytes that arrived from the network.
func session_methods.feed(session, bytes){}

// handshake() -> bool
// Advances the handshake: true when it is done, false while it waits for
// the peer; raises when it fails (a certificate that does not verify, for
// one).
func session_methods.handshake(session){}

// read() -> string?
// The plaintext decrypted so far ("" for none), or null once the peer
// closed the session (close_notify).
func session_methods.read(session){}

// write(plaintext: string)
// Encrypts plaintext for [Session.take]; only after the handshake.
func session_methods.write(session, plaintext){}

// take() -> string
// The bytes to send to the network ("" for none); call it after every
// other method, which may all produce some.
func session_methods.take(session){}

// close()
// Queues a close_notify for [Session.take], when the handshake got that
// far.
func session_methods.close(session){}

// info() -> Info
// What was negotiated so far; fields that are not known yet are null.
func session_methods.info(session){}

// ------------------------------------------------------------ certificates

// self_signed(names: {string}, days?: int) -> Certificate
// A certificate for local development, valid for days (365), with an EC
// P-256 key.
// [names]: host names or IP addresses; the first is the subject
//
//   local c = tls.self_signed({"localhost", "127.0.0.1"})
//   local ctx = tls.context({server: true, cert: c.cert, key: c.key})
func m.self_signed(names, days){}

// version() -> string
// The OpenSSL version text.
func m.version(){}

return m
