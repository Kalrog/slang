// slang/jwt: JSON Web Tokens (RFC 7519) over slang/crypto.
//
//   local jwt = require("slang/jwt")
//   local token = jwt.sign({sub: "42"}, secret, {expires_in: 3600})
//   local claims = jwt.verify(token, secret)        // {sub: "42", iat, exp}
//
// A key is a secret string for HS256/384/512, or a [crypto.Key]: RSA for
// RS256/384/512 and PS256/384/512, EC for ES256/384/512, Ed25519 for
// EdDSA. The algorithm defaults to the one that fits the key (HS256,
// RS256, ES256/384/512 by curve, EdDSA), and [verify] accepts only that
// one unless told otherwise, so a token cannot pick a weaker algorithm.
// Errors raise "jwt: ..." ("jwt: expired", "jwt: bad signature", ...).

// A token's claims: any JSON object. The registered ones [sign] sets and
// [verify] checks are below; times are seconds since the epoch.
// type Claims = {iss?: string, sub?: string, aud?: string | {string},
//   exp?: int, nbf?: int, iat?: int}
// [exp]: when the token expires
// [nbf]: when it becomes valid
// [iat]: when it was issued; [sign] always sets it

// What [sign] accepts besides the claims.
// type SignOptions = {alg?: string, expires_in?: int, not_before?: int,
//   issuer?: string, subject?: string, audience?: string | {string},
//   header?: table, now?: int}
// [alg]: "HS256", "RS256", "ES256", "EdDSA", ... (by default the key's)
// [expires_in]: seconds from now: sets exp
// [not_before]: seconds from now: sets nbf
// [issuer]: sets iss
// [subject]: sets sub
// [audience]: sets aud
// [header]: extra header fields, such as kid
// [now]: the time in seconds since the epoch, for tests

// What [verify] checks.
// type VerifyOptions = {alg?: string, algs?: {string}, leeway?: int,
//   now?: int, issuer?: string, audience?: string}
// [alg]: the algorithm accepted (by default the one that fits the key)
// [algs]: the algorithms accepted, instead of alg
// [leeway]: seconds of clock skew allowed for exp and nbf (0)
// [now]: the time in seconds since the epoch, for tests
// [issuer]: iss must equal it
// [audience]: aud must equal it or, as a list, contain it

// A token [decode] read: its two JSON parts.
// type Decoded = {header: table, claims: Claims}

local crypto = require("slang/crypto")
local encoding = require("slang/encoding")
local json = require("slang/json")
local time = require("slang/time")
local str = require("slang/string")

local jwt = {}

// alg -> {kind, digest, options}
local algorithms = {
  HS256: {kind: "hmac", digest: "sha256"},
  HS384: {kind: "hmac", digest: "sha384"},
  HS512: {kind: "hmac", digest: "sha512"},
  RS256: {kind: "rsa", digest: "sha256"},
  RS384: {kind: "rsa", digest: "sha384"},
  RS512: {kind: "rsa", digest: "sha512"},
  PS256: {kind: "rsa", digest: "sha256", options: {padding: "pss"}},
  PS384: {kind: "rsa", digest: "sha384", options: {padding: "pss"}},
  PS512: {kind: "rsa", digest: "sha512", options: {padding: "pss"}},
  ES256: {kind: "ec", digest: "sha256", bits: 256, options: {encoding: "raw"}},
  ES384: {kind: "ec", digest: "sha384", bits: 384, options: {encoding: "raw"}},
  ES512: {kind: "ec", digest: "sha512", bits: 521, options: {encoding: "raw"}},
  EdDSA: {kind: "ed25519", digest: null},
}

local func key_kind(key){
  if(type(key) == "string"){
    return "hmac"
  }
  if(type(key) == "crypto.key"){
    return key:type()
  }
  error("jwt: a key must be a secret string or a crypto key, got ", type(key))
}

local func default_alg(key){
  local kind = key_kind(key)
  if(kind == "hmac"){ return "HS256" }
  if(kind == "rsa"){ return "RS256" }
  if(kind == "ed25519"){ return "EdDSA" }
  if(kind == "ec"){
    local bits = key:bits()
    return bits == 384 and "ES384" or bits == 521 and "ES512" or "ES256"
  }
  error("jwt: no algorithm for a ", kind, " key")
}

// the algorithm entry for alg, checked against the key
local func algorithm(alg, key){
  local a = algorithms[alg]
  if(a == null){
    error("jwt: unsupported algorithm ", alg)
  }
  local kind = key_kind(key)
  if(kind != a.kind or (a.bits != null and key:bits() != a.bits)){
    error("jwt: the key does not fit ", alg)
  }
  return a
}

local func b64(s){ return encoding.base64url_encode(s) }

local func now(options){
  return options.now or to_int(time.now())
}

// sign(claims: Claims, key: string | crypto.Key,
//   options?: SignOptions) -> string
// A signed token with claims (copied; the options add to them). Raises
// when the key does not fit the algorithm, or is a public key.
func jwt.sign(claims, key, options){
  options = options or {}
  local alg = options.alg or default_alg(key)
  local a = algorithm(alg, key)
  local header = {alg: alg, typ: "JWT"}
  for(let local e in entries(options.header or {})){
    header[e[0]] = e[1]
  }
  local body = {}
  for(let local e in entries(claims or {})){
    body[e[0]] = e[1]
  }
  local t = now(options)
  body.iat = body.iat or t
  if(options.expires_in != null){ body.exp = t + options.expires_in }
  if(options.not_before != null){ body.nbf = t + options.not_before }
  if(options.issuer != null){ body.iss = options.issuer }
  if(options.subject != null){ body.sub = options.subject }
  if(options.audience != null){ body.aud = options.audience }
  local input = concat(b64(json.encode(header)), ".", b64(json.encode(body)))
  local signature = null
  if(a.kind == "hmac"){
    signature = crypto.hmac(a.digest, key, input)
  } else {
    if(not key:is_private()){
      error("jwt: signing needs a private key")
    }
    signature = key:sign(a.digest, input, a.options)
  }
  return concat(input, ".", b64(signature))
}

// the three parts of a token, decoded: {header, claims, signature, input}
local func split(token){
  if(type(token) != "string"){
    error("jwt: malformed token")
  }
  local parts = str.split(token, ".")
  if(len(parts) != 3){
    error("jwt: malformed token")
  }
  local header_text = encoding.base64url_decode(parts[0])
  local claims_text = encoding.base64url_decode(parts[1])
  local signature = encoding.base64url_decode(parts[2])
  if(header_text == null or claims_text == null or signature == null){
    error("jwt: malformed token")
  }
  local r = pcall(func(){
    return {json.decode(header_text), json.decode(claims_text)}
  })
  if(r[0] == "err" or type(r[1][0]) != "table" or type(r[1][1]) != "table"){
    error("jwt: malformed token")
  }
  return {
    header: r[1][0], claims: r[1][1], signature: signature,
    input: concat(parts[0], ".", parts[1])
  }
}

// decode(token: string) -> Decoded
// The header and claims of a token, without checking the signature or
// anything else: never trust them. Raises "jwt: malformed token".
func jwt.decode(token){
  local t = split(token)
  return {header: t.header, claims: t.claims}
}

local func contains(list, v){
  for(let local x in values(list)){
    if(x == v){
      return true
    }
  }
  return false
}

// verify(token: string, key: string | crypto.Key,
//   options?: VerifyOptions) -> Claims
// The claims of a token whose algorithm is accepted, whose signature is
// valid for key, which has not expired and is valid already (exp and nbf,
// when present), and whose iss and aud match the options that ask. Raises
// "jwt: ..." otherwise.
//
//   local r = pcall(jwt.verify, token, public_key, {algs: {"RS256", "PS256"}})
func jwt.verify(token, key, options){
  options = options or {}
  local t = split(token)
  local accepted = options.algs or {options.alg or default_alg(key)}
  local alg = t.header.alg
  if(type(alg) != "string" or not contains(accepted, alg)){
    error("jwt: algorithm ", string(alg), " not accepted")
  }
  local a = algorithm(alg, key)
  local ok = false
  if(a.kind == "hmac"){
    ok = crypto.equal(crypto.hmac(a.digest, key, t.input), t.signature)
  } else {
    ok = key:verify(a.digest, t.input, t.signature, a.options)
  }
  if(not ok){
    error("jwt: bad signature")
  }
  local c = t.claims
  local at = now(options)
  local leeway = options.leeway or 0
  if(c.exp != null and
    (type(c.exp) != "int" and type(c.exp) != "double" or at >= c.exp + leeway)){
    error("jwt: expired")
  }
  if(c.nbf != null and
    (type(c.nbf) != "int" and type(c.nbf) != "double" or at + leeway < c.nbf)){
    error("jwt: not valid yet")
  }
  if(options.issuer != null and c.iss != options.issuer){
    error("jwt: wrong issuer")
  }
  if(options.audience != null){
    local aud = c.aud
    if(not(aud == options.audience or
      (type(aud) == "table" and contains(aud, options.audience)))){
      error("jwt: wrong audience")
    }
  }
  return c
}

return jwt
