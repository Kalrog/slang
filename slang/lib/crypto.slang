// slang/crypto: the crypto native extension (OpenSSL) plus what web code
// builds from it: password hashes, random tokens, signed and sealed values.
//
//   crypto.hash(digest, data), crypto.hmac(digest, key, data), crypto.equal,
//   crypto.random_bytes(n), crypto.hasher(digest), crypto.pbkdf2,
//   crypto.scrypt, crypto.encrypt, crypto.decrypt, crypto.private_key,
//   crypto.public_key, crypto.generate_key     as in the native module
//   crypto.hex(digest, data) -> the hash as lowercase hex
//   crypto.token(n) -> n random bytes (32 by default) as base64url text
//   crypto.hash_password(password) -> "$scrypt$ln=15,r=8,p=1$salt$hash"
//   crypto.verify_password(password, stored) -> bool
//   crypto.hash_password_async / verify_password_async -> Futures, the work
//     on libuv's thread pool (an scrypt hash takes tens of milliseconds)
//   crypto.sign_value(secret, value) -> "value.mac"
//   crypto.unsign_value(secret, signed) -> value, or null when tampered
//   crypto.seal(key, text, [aad]) -> base64url of iv, ciphertext and tag
//   crypto.unseal(key, sealed, [aad]) -> text, or null
//
// Password hashes use scrypt with n = 2^15, r = 8, p = 1 (32 MiB, the
// OWASP recommendation) and a 16-byte salt; verify_password also accepts
// "$pbkdf2-sha256$i=...$salt$hash". seal uses AES-256-GCM with a random
// 12-byte iv and needs a 32-byte key.
local native = require("crypto")
local encoding = require("slang/encoding")
local str = require("slang/string")

local crypto = {}
for(let local e in entries(native)){
  crypto[e[0]] = e[1]
}

func crypto.hex(digest, data){
  return encoding.hex_encode(native.hash(digest, data))
}

func crypto.token(n){
  return encoding.base64url_encode(native.random_bytes(n or 32))
}

// ------------------------------------------------------------ passwords

local LOG_N = 15
local R = 8
local P = 1
local KEY_LEN = 32

local func b64(s){ return encoding.base64_encode(s) }
local func unb64(s){ return encoding.base64_decode(s) }

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

func crypto.hash_password(password){
  local salt = native.random_bytes(16)
  return format_hash(
    salt,
    native.scrypt(password, salt, 1 << LOG_N, R, P, KEY_LEN),
  )
}

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

func crypto.hash_password_async(password){
  local async = require("slang/async")
  local salt = native.random_bytes(16)
  return async.wrap(func(cb){
    native.scrypt_async(password, salt, 1 << LOG_N, R, P, KEY_LEN, cb)
  }):then(func(key){ return format_hash(salt, key) })
}

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
  return encoding.base64url_encode(native.hmac("sha256", secret, value))
}

func crypto.sign_value(secret, value){
  return concat(value, ".", mac(secret, value))
}

func crypto.unsign_value(secret, signed){
  if(type(signed) != "string"){
    return null
  }
  // the mac is the part after the last dot; the value may contain dots
  local dot = - 1
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

func crypto.seal(key, text, aad){
  local iv = native.random_bytes(12)
  return encoding.base64url_encode(concat(
    iv,
    native.encrypt("aes-256-gcm", key, iv, text, aad),
  ))
}

func crypto.unseal(key, sealed, aad){
  local raw = type(sealed) == "string" and encoding.base64url_decode(sealed)
  if(not raw or len(raw) < 28){
    return null
  }
  return native.decrypt(
    "aes-256-gcm", key, str.substring(raw, 0, 12), str.substring(raw, 12), aad
  )
}

return crypto
