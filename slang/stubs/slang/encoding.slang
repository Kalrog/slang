// slang/encoding: the byte encodings web code needs (base64, hex,
// percent-encoding, query strings) and checksums, built into the VM.
//
//   local enc = require("slang/encoding")
//   enc.base64_encode("hi!")                  // "aGkh"
//   enc.hex_encode(enc.sha256("abc"))         // "ba7816bf..."
//   enc.query_encode({q: "slang lang", page: 2})   // "page=2&q=slang+lang"
//
// Strings are byte strings, so every encoder takes any bytes. Decoders
// return null on malformed input instead of raising (untrusted input is
// the normal case).
local m = {}

// ------------------------------------------------------------ base64

// base64_encode(s: string) -> string
// s in standard base64, with "=" padding.
func m.base64_encode(s){}

// base64_decode(s: string) -> string?
// The bytes of standard base64 text with or without padding, or null.
func m.base64_decode(s){}

// base64url_encode(s: string, pad?: bool) -> string
// s in URL-safe base64, without padding unless pad is true.
func m.base64url_encode(s, pad){}

// base64url_decode(s: string) -> string?
// The bytes of URL-safe base64 text with or without padding, or null.
func m.base64url_decode(s){}

// ------------------------------------------------------------ hex

// hex_encode(s: string) -> string
// s as lower-case hex digits, two per byte.
func m.hex_encode(s){}

// hex_decode(s: string) -> string?
// The bytes of hex text (either case), or null.
func m.hex_decode(s){}

// ------------------------------------------------------------ percent-encoding

// url_encode(s: string) -> string
// s percent-encoded as a URI component (RFC 3986): everything but A-Z a-z
// 0-9 - . _ ~ is escaped.
func m.url_encode(s){}

// url_decode(s: string) -> string?
// s with its %XX escapes decoded, or null when a "%" is not followed by
// two hex digits.
func m.url_decode(s){}

// form_encode(s: string) -> string
// Like [url_encode], but a space becomes "+"
// (application/x-www-form-urlencoded).
func m.form_encode(s){}

// form_decode(s: string) -> string?
// Like [url_decode], but "+" becomes a space.
func m.form_decode(s){}

// query_encode(t: table) -> string
// The string, number and boolean fields of t as a form query string, in
// key order so the result is stable. A list value repeats its key once
// per element; null, false and other values are left out.
//   enc.query_encode({b: "x y!", a: 1})   // "a=1&b=x+y%21"
func m.query_encode(t){}

// query_decode(s?: string) -> {[string]: string}
// The pairs of a form query string. A leading "?" is skipped, a repeated
// key keeps its last value and a pair that does not decode is skipped;
// null gives {}.
//   enc.query_decode("a=1&b=x+y%21&flag")   // {a: "1", b: "x y!", flag: ""}
func m.query_decode(s){}

// ------------------------------------------------------------ checks

// utf8_valid(s: string) -> bool
// Whether s is valid UTF-8.
func m.utf8_valid(s){}

// crc32(s: string) -> int
// The CRC-32 checksum of s.
func m.crc32(s){}

// sha256(s: string) -> string
// The SHA-256 digest of s: 32 raw bytes ([hex_encode] them for text).
func m.sha256(s){}

// mask(data: string, key: string) -> string
// data XOR key repeated (WebSocket masking; the same call unmasks). Raises
// an error for an empty key.
func m.mask(data, key){}

return m
