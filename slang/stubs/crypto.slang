// crypto: the native binding of the parts of OpenSSL 3 (libcrypto) that web
// applications need. Most code should use slang/crypto (and slang/jwt),
// which build on it.
//
//   local crypto = require("crypto")
//   crypto.hash("sha256", "abc")  // 32 raw bytes
//   crypto.hasher("sha256"):update("a"):update("bc"):digest()
//
// Digests are OpenSSL names ("sha1", "sha256", "sha384", "sha512",
// "sha3-256", "md5", ...). Results are raw byte strings; slang/encoding
// makes hex or base64 of them. Errors are raised with OpenSSL's message.
local m = {}

local hasher_methods = {}
local hasher_meta = {__index: hasher_methods, __type: "crypto.hasher"}

local key_methods = {}
local key_meta = {__index: key_methods, __type: "crypto.key"}

// ------------------------------------------------------------ hashes and MACs

// hash(digest, data) -> the raw digest of data
func m.hash(digest, data){}

// hmac(digest, key, data) -> the raw HMAC of data under key
func m.hmac(digest, key, data){}

// random_bytes(n) -> n cryptographically random bytes, n from 0 to 1048576
func m.random_bytes(n){}

// equal(a, b) -> whether the strings are equal, in time that depends only
// on their lengths (for comparing MACs and tokens)
func m.equal(a, b){}

// hasher(digest) -> a crypto.hasher: update(data) as often as needed, then
// digest() once
func m.hasher(digest){ return {meta: hasher_meta} }

// hasher:update(data) -> hasher, with data added
func hasher_methods.update(hasher, data){}

// hasher:digest() -> the raw digest; the hasher raises on further use
func hasher_methods.digest(hasher){}

// ------------------------------------------------------------ key derivation

// pbkdf2(digest, password, salt, iterations, length) -> length bytes (1 to
// 4096) derived with PBKDF2-HMAC; at least one iteration
func m.pbkdf2(digest, password, salt, iterations, length){}

// scrypt(password, salt, n, r, p, length) -> length bytes (1 to 4096)
// derived with scrypt; n a power of two above 1, r and p positive
func m.scrypt(password, salt, n, r, p, length){}

// pbkdf2_async(digest, password, salt, iterations, length, cb) runs pbkdf2
// on libuv's thread pool and calls cb(err, bytes) from the loop
func m.pbkdf2_async(digest, password, salt, iterations, length, cb){}

// scrypt_async(password, salt, n, r, p, length, cb) runs scrypt on libuv's
// thread pool and calls cb(err, bytes) from the loop
func m.scrypt_async(password, salt, n, r, p, length, cb){}

// ------------------------------------------------------------ encryption

// encrypt(cipher, key, iv, plaintext, [aad]) -> the ciphertext followed by
// the 16-byte tag. cipher is an AEAD: "aes-128-gcm", "aes-256-gcm" or
// "chacha20-poly1305"; key as long as the cipher needs, iv 8 to 64 bytes
// (12 is usual); aad is authenticated but not encrypted.
func m.encrypt(cipher, key, iv, plaintext, aad){}

// decrypt(cipher, key, iv, sealed, [aad]) -> the plaintext, or null when
// the data, the aad, the key or the iv do not match the tag
func m.decrypt(cipher, key, iv, sealed, aad){}

// ------------------------------------------------------------ keys

// private_key(pem, [passphrase]) -> a crypto.key from a PEM private key
func m.private_key(pem, passphrase){ return {meta: key_meta} }

// public_key(pem) -> a crypto.key from a PEM public key
// ("BEGIN PUBLIC KEY")
func m.public_key(pem){ return {meta: key_meta} }

// generate_key(type, [param]) -> a new private crypto.key: ("rsa", [bits])
// with bits 1024 to 16384 (2048), ("ec", [curve]) with curve "P-256" by
// default, or ("ed25519")
func m.generate_key(type, param){ return {meta: key_meta} }

// key:sign(digest, data, [options]) -> the signature of data; needs a
// private key. options: {padding: "pss"} for RSA-PSS (salt as long as the
// digest), {encoding: "raw"} for ECDSA signatures as r || s (the JWT form)
// instead of DER. Ed25519 ignores the digest (pass null).
func key_methods.sign(key, digest, data, options){}

// key:verify(digest, data, signature, [options]) -> whether signature is a
// valid signature of data; options as for sign
func key_methods.verify(key, digest, data, signature, options){}

// key:type() -> "rsa", "rsa-pss", "ec", "ed25519", "ed448" or "other"
func key_methods.type(key){}

// key:bits() -> the size of the key in bits
func key_methods.bits(key){}

// key:is_private() -> whether the key holds the private half
func key_methods.is_private(key){}

// key:public_pem() -> the public key as PEM ("BEGIN PUBLIC KEY")
func key_methods.public_pem(key){}

// key:private_pem() -> the private key as unencrypted PKCS#8 PEM; raises
// for a public key
func key_methods.private_pem(key){}

// key:public_key() -> the public half as a crypto.key of its own
func key_methods.public_key(key){ return {meta: key_meta} }

// ------------------------------------------------------------ version

// version() -> the OpenSSL version text
func m.version(){}

return m
