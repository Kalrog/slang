// slang/hash: checksums and digests, built into the VM. slang/crypto (an
// OpenSSL extension) has the others and HMAC.
//
//   local hash = require("slang/hash")
//   hash.crc32("abc")                          // 891568578
//   str.format("%x", hash.sha256("abc"))       // "ba7816bf..."
local m = {}

// crc32(s: string) -> int
// The CRC-32 (IEEE) checksum of s.
func m.crc32(s){}

// fnv1a(s: string) -> int
// The 64-bit FNV-1a hash of s, as an int; not for security, for keys
// and caches. str.format("%x", h) writes it as hex.
func m.fnv1a(s){}

// sha256(s: string) -> string
// The SHA-256 digest of s: 32 raw bytes.
func m.sha256(s){}

return m
