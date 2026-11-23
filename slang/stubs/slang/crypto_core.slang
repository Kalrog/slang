// slang/crypto_core: hashes, MACs, random bytes, key derivation and
// authenticated encryption, built into the VM from Zig's std.crypto: the
// same on every platform, without OpenSSL. slang/crypto has all of it
// under the same names, and keys; most code should use that.
//
//   local core = require("slang/crypto_core")
//   core.hash("sha256", "abc")  // 32 raw bytes
//   core.hasher("sha256"):update("a"):update("bc"):digest()
//
// Digests (any case): "md5", "sha1", "sha224", "sha256", "sha384",
// "sha512", "sha512-224", "sha512-256", "sha3-224", "sha3-256",
// "sha3-384", "sha3-512", "blake2b512", "blake2s256". Results are raw byte
// strings; slang/encoding makes hex or base64 of them.
local m = {}

// A digest computed piece by piece: [Hasher.update] as often as needed,
// then [Hasher.digest] once.
// type Hasher
local hasher_methods = {}
local hasher_meta = {__index: hasher_methods, __type: "crypto.hasher"}

// ------------------------------------------------------------ hashes and MACs

// hash(digest: string, data: string) -> string
// The raw digest of data (a string or a buffer, as every data argument).
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
func m.hasher(digest){ return {@meta: hasher_meta} }

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
// [iv]: 12 bytes; never reuse one with the same key
// [aad]: data that is authenticated but not encrypted
func m.encrypt(cipher, key, iv, plaintext, aad){}

// decrypt(cipher: string, key: string, iv: string, sealed: string,
//   aad?: string) -> string?
// The plaintext of what [encrypt] made, or null when the data, the aad,
// the key or the iv do not match the tag.
func m.decrypt(cipher, key, iv, sealed, aad){}

return m
