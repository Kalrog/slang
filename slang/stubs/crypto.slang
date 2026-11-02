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

// A digest computed piece by piece: [Hasher.update] as often as needed,
// then [Hasher.digest] once.
// type Hasher
local hasher_methods = {}
local hasher_meta = {__index: hasher_methods, __type: "crypto.hasher"}

local key_methods = {}
local key_get = {}

// A private or public key (RSA, EC, Ed25519, ...) from [private_key],
// [public_key] or [generate_key]; type(key) is "crypto.key".
// type Key
local key_meta = {__index: key_methods, __get: key_get, __type: "crypto.key"}

// type(self) -> string
// "rsa", "rsa-pss", "ec", "ed25519", "ed448" or "other".
func key_get.type(self){}

// bits(self) -> int
// The size of the key in bits (521 for a P-521 key).
func key_get.bits(self){}

// private(self) -> bool
// Whether the key holds the private half.
func key_get.private(self){}

// ------------------------------------------------------------ hashes and MACs

// hash(digest: string, data: string) -> string
// The raw digest of data.
func m.hash(digest, data){}

// hmac(digest: string, key: string, data: string) -> string
// The raw HMAC of data under key.
func m.hmac(digest, key, data){}

// random_bytes(n: int) -> string
// n cryptographically random bytes, n from 0 to 1048576.
func m.random_bytes(n){}

// equal(a: string, b: string) -> bool
// Whether the strings are equal, in time that depends only on their
// lengths (for comparing MACs and tokens).
func m.equal(a, b){}

// hasher(digest: string) -> Hasher
// A hasher for incremental hashing.
func m.hasher(digest){ return {meta: hasher_meta} }

// update(data: string) -> Hasher
// Adds data; returns the hasher, so calls chain.
func hasher_methods.update(hasher, data){}

// digest() -> string
// The raw digest; the hasher raises on further use.
func hasher_methods.digest(hasher){}

// ------------------------------------------------------------ key derivation

// pbkdf2(digest: string, password: string, salt: string, iterations: int,
//   length: int) -> string
// length bytes (1 to 4096) derived with PBKDF2-HMAC; at least one
// iteration.
func m.pbkdf2(digest, password, salt, iterations, length){}

// scrypt(password: string, salt: string, n: int, r: int, p: int,
//   length: int) -> string
// length bytes (1 to 4096) derived with scrypt; n a power of two above 1,
// r and p positive.
func m.scrypt(password, salt, n, r, p, length){}

// pbkdf2_async(digest: string, password: string, salt: string,
//   iterations: int, length: int, cb: func(err: string?, bytes: string?))
// Runs [pbkdf2] on libuv's thread pool and calls cb from the loop.
func m.pbkdf2_async(digest, password, salt, iterations, length, cb){}

// scrypt_async(password: string, salt: string, n: int, r: int, p: int,
//   length: int, cb: func(err: string?, bytes: string?))
// Runs [scrypt] on libuv's thread pool and calls cb from the loop.
func m.scrypt_async(password, salt, n, r, p, length, cb){}

// ------------------------------------------------------------ encryption

// encrypt(cipher: string, key: string, iv: string, plaintext: string,
//   aad?: string) -> string
// The ciphertext followed by the 16-byte tag.
// [cipher]: an AEAD: "aes-128-gcm", "aes-256-gcm" or "chacha20-poly1305"
// [key]: as long as the cipher needs (32 bytes for aes-256-gcm)
// [iv]: 8 to 64 bytes (12 is usual); never reuse one with the same key
// [aad]: data that is authenticated but not encrypted
func m.encrypt(cipher, key, iv, plaintext, aad){}

// decrypt(cipher: string, key: string, iv: string, sealed: string,
//   aad?: string) -> string?
// The plaintext of what [encrypt] made, or null when the data, the aad,
// the key or the iv do not match the tag.
func m.decrypt(cipher, key, iv, sealed, aad){}

// ------------------------------------------------------------ keys

// How [Key.sign] and [Key.verify] work beyond the key's own algorithm.
// type SignOptions = {padding?: string, encoding?: string}
// [padding]: "pss" for RSA-PSS (salt as long as the digest)
// [encoding]: "raw" for ECDSA signatures as r || s (JWT's) instead of DER

// private_key(pem: string, passphrase?: string) -> Key
// A key from a PEM private key (encrypted ones need the passphrase).
func m.private_key(pem, passphrase){ return {meta: key_meta} }

// public_key(pem: string) -> Key
// A key from a PEM public key ("BEGIN PUBLIC KEY").
func m.public_key(pem){ return {meta: key_meta} }

// generate_key(type: string, param?: int | string) -> Key
// A new private key: ("rsa", [bits]) with bits 1024 to 16384 (2048 by
// default), ("ec", [curve]) with curve "P-256" by default, or
// ("ed25519").
//
//   local key = crypto.generate_key("ec", "P-384")
func m.generate_key(type, param){ return {meta: key_meta} }

// sign(digest: string?, data: string, options?: SignOptions) -> string
// The signature of data; needs a private key. Ed25519 ignores the digest
// (pass null).
func key_methods.sign(key, digest, data, options){}

// verify(digest: string?, data: string, signature: string,
//   options?: SignOptions) -> bool
// Whether signature is a valid signature of data; options as for
// [Key.sign].
func key_methods.verify(key, digest, data, signature, options){}

// public_pem() -> string
// The public key as PEM ("BEGIN PUBLIC KEY").
func key_methods.public_pem(key){}

// private_pem() -> string
// The private key as unencrypted PKCS#8 PEM; raises for a public key.
func key_methods.private_pem(key){}

// public_key() -> Key
// The public half as a key of its own.
func key_methods.public_key(key){ return {meta: key_meta} }

// ------------------------------------------------------------ version

// version() -> string
// The OpenSSL version text.
func m.version(){}

return m
