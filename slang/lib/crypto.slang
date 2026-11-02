// slang/crypto: the crypto native extension (OpenSSL) plus what web code
// builds from it: password hashes, random tokens, signed and sealed values.
//
//   local crypto = require("slang/crypto")
//   local stored = crypto.hash_password("hunter2")
//   crypto.verify_password("hunter2", stored)       // true
//   local cookie = crypto.sign(secret, "user=42")
//   crypto.verify_signed(secret, cookie)            // "user=42"
//   crypto.hex("sha256", "abc")                     // "ba7816bf..."
//   local key = crypto.generate_key("ec")
//   key.type, key.bits, key.private                 // "ec", 256, true
//
// The native extension's functions are here too, under the same names:
// hash, hmac, equal, random_bytes, hasher, pbkdf2, scrypt, encrypt,
// decrypt, private_key, public_key, generate_key, version and the _async
// forms; [c] is the extension itself. Results are raw byte strings;
// slang/encoding makes hex or base64 of them.
//
// Password hashes use scrypt with n = 2^15, r = 8, p = 1 (32 MiB, the
// OWASP recommendation) and a 16-byte salt; [verify_password] also accepts
// "$pbkdf2-sha256$i=...$salt$hash". [seal] uses AES-256-GCM with a random
// 12-byte iv and needs a 32-byte key.

// A key, as private_key, public_key and generate_key make it: key.type,
// key.bits and key.private, key:sign(...), key:verify(...),
// key:public_pem().
// type Key = native.Key

// An incremental hasher, from hasher.
// type Hasher = native.Hasher

local native = require("crypto")
local encoding = require("slang/encoding")
local str = require("slang/string")

local crypto = {}
for(let local e in entries(native)){
  crypto[e[0]] = e[1]
}
// The native extension under this module (OpenSSL).
crypto.c = native

// hex(digest: string, data: string) -> string
// The digest of data as lowercase hex.
func crypto.hex(digest, data){
  return encoding.hex.encode(native.hash(digest, data))
}

// token(n?: int) -> string
// n random bytes (32 by default) as base64url text: a session id, a CSRF
// token, a key for a reset link.
func crypto.token(n){
  return encoding.base64url.encode(native.random_bytes(n or 32))
}

// ------------------------------------------------------------ passwords

local LOG_N = 15
local R = 8
local P = 1
local KEY_LEN = 32

local func b64(s){ return encoding.base64.encode(s) }
local func unb64(s){ return encoding.base64.decode(s) }

local func format_hash(salt, key){
  return concat(
    "$scrypt$ln=", string(LOG_N), ",r=", string(R), ",p=", string(P), "$",
    b64(salt), "$", b64(key)
  )
}

// the parts of a stored hash: {kind, params, salt, key}, or null
local func parse_hash(stored){
  if(type(stored) != "string"){
    return null
  }
  local parts = str.split(stored, "$")
  if(len(parts) != 5 or parts[0] != ""){
    return null
  }
  local params = {}
  for(let local kv in values(str.split(parts[2], ","))){
    local eq = str.index_of(kv, "=")
    if(eq > 0){
      params[str.substring(kv, 0, eq)] = str.to_number(
        str.substring(kv, eq + 1),
      )
    }
  }
  local salt = unb64(parts[3])
  local key = unb64(parts[4])
  if(salt == null or key == null or len(key) == 0){
    return null
  }
  return {kind: parts[1], params: params, salt: salt, key: key}
}

// the arguments of the derivation that produced h, or null if unknown
local func derivation(h){
  if(h.kind == "scrypt" and type(h.params.ln) == "int" and
    type(h.params.r) == "int" and type(h.params.p) == "int" and
    h.params.ln > 0 and h.params.ln < 31){
    return {scrypt: true, n: 1 << h.params.ln, r: h.params.r, p: h.params.p}
  }
  if(h.kind == "pbkdf2-sha256" and type(h.params.i) == "int" and h.params.i > 0){
    return {scrypt: false, iterations: h.params.i}
  }
  return null
}

// hash_password(password: string) -> string
// A salted scrypt hash to store, "$scrypt$ln=15,r=8,p=1$salt$hash". It
// takes tens of milliseconds on purpose; a server should prefer
// [hash_password_async].
func crypto.hash_password(password){
  local salt = native.random_bytes(16)
  return format_hash(
    salt,
    native.scrypt(password, salt, 1 << LOG_N, R, P, KEY_LEN),
  )
}

// verify_password(password: string, stored: string) -> bool
// Whether password matches a hash [hash_password] made (or a
// $pbkdf2-sha256$ one); false for a stored value it cannot read.
func crypto.verify_password(password, stored){
  local h = parse_hash(stored)
  local d = h and derivation(h)
  if(d == null){
    return false
  }
  local key = null
  if(d.scrypt){
    key = native.scrypt(password, h.salt, d.n, d.r, d.p, len(h.key))
  } else {
    key = native.pbkdf2("sha256", password, h.salt, d.iterations, len(h.key))
  }
  return native.equal(key, h.key)
}

// hash_password_async(password: string) -> async.Future
// [hash_password] on libuv's thread pool: a Future of the hash, while the
// loop stays free.
func crypto.hash_password_async(password){
  local async = require("slang/async")
  local salt = native.random_bytes(16)
  return async.wrap(func(cb){
    native.scrypt_async(password, salt, 1 << LOG_N, R, P, KEY_LEN, cb)
  }):then(func(key){ return format_hash(salt, key) })
}

// verify_password_async(password: string, stored: string) -> async.Future
// [verify_password] on libuv's thread pool: a Future of the bool.
func crypto.verify_password_async(password, stored){
  local async = require("slang/async")
  local h = parse_hash(stored)
  local d = h and derivation(h)
  if(d == null){
    return async.value(false)
  }
  return async.wrap(func(cb){
    if(d.scrypt){
      native.scrypt_async(password, h.salt, d.n, d.r, d.p, len(h.key), cb)
    } else {
      native.pbkdf2_async(
        "sha256", password, h.salt, d.iterations, len(h.key), cb
      )
    }
  }):then(func(key){ return native.equal(key, h.key) })
}

// ------------------------------------------------------------ signed and sealed values

local func mac(secret, value){
  return encoding.base64url.encode(native.hmac("sha256", secret, value))
}

// sign(secret: string, value: string) -> string
// "value.mac": value with an HMAC-SHA256 of it under secret, base64url.
// Anyone can read value; only who knows secret can make one that
// [verify_signed] accepts ([seal] hides the value too).
func crypto.sign(secret, value){
  return concat(value, ".", mac(secret, value))
}

// verify_signed(secret: string, signed: string) -> string?
// The value [sign] signed, or null when signed was not made with secret
// or was changed (a failed check, not an error).
func crypto.verify_signed(secret, signed){
  if(type(signed) != "string"){
    return null
  }
  // the mac is the part after the last dot; the value may contain dots
  local dot = -1
  for(local i = len(signed) - 1; i >= 0; i = i - 1){
    if(str.byte_at(signed, i) == 46){
      dot = i
      break
    }
  }
  if(dot < 0){
    return null
  }
  local value = str.substring(signed, 0, dot)
  if(not native.equal(mac(secret, value), str.substring(signed, dot + 1))){
    return null
  }
  return value
}

// seal(key: string, text: string, aad?: string) -> string
// text encrypted and authenticated (AES-256-GCM, a random iv), as
// base64url of iv, ciphertext and tag.
// [key]: 32 bytes, such as native.random_bytes(32) kept secret
// [aad]: data it is bound to without containing it (a user id); unseal needs it
func crypto.seal(key, text, aad){
  local iv = native.random_bytes(12)
  return encoding.base64url.encode(concat(
    iv,
    native.encrypt("aes-256-gcm", key, iv, text, aad),
  ))
}

// unseal(key: string, sealed: string, aad?: string) -> string?
// The text [seal] sealed, or null when sealed is malformed, was changed,
// or the key or the aad do not match.
func crypto.unseal(key, sealed, aad){
  local raw = type(sealed) == "string" and encoding.base64url.decode(sealed)
  if(not raw or len(raw) < 28){
    return null
  }
  return native.decrypt(
    "aes-256-gcm", key, str.substring(raw, 0, 12), str.substring(raw, 12), aad
  )
}

return crypto
