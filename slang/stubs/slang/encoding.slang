// slang/encoding: the byte encodings web code needs, built into the VM.
// Strings are byte strings, so every encoder takes any bytes. Decoders
// return null on malformed input (untrusted input is the normal case).
local m = {}

// ------------------------------------------------------------ base64

// base64_encode(s) -> s in standard base64, with "=" padding
func m.base64_encode(s){}

// base64_decode(s) -> the bytes of standard base64 text with or without
// padding, or null
func m.base64_decode(s){}

// base64url_encode(s, [pad]) -> s in URL-safe base64, without padding unless
// pad is true
func m.base64url_encode(s, pad){}

// base64url_decode(s) -> the bytes of URL-safe base64 text with or without
// padding, or null
func m.base64url_decode(s){}

// ------------------------------------------------------------ hex

// hex_encode(s) -> s as lower-case hex digits, two per byte
func m.hex_encode(s){}

// hex_decode(s) -> the bytes of hex text (either case), or null
func m.hex_decode(s){}

// ------------------------------------------------------------ percent-encoding

// url_encode(s) -> s percent-encoded as a URI component (RFC 3986):
// everything but A-Z a-z 0-9 - . _ ~ is escaped
func m.url_encode(s){}

// url_decode(s) -> s with its %XX escapes decoded, or null when a "%" is
// not followed by two hex digits
func m.url_decode(s){}

// form_encode(s) -> like url_encode, but a space becomes "+"
// (application/x-www-form-urlencoded)
func m.form_encode(s){}

// form_decode(s) -> like url_decode, but "+" becomes a space
func m.form_decode(s){}

// query_encode(t) -> the string, number and boolean fields of t as a form
// query string, in key order so the result is stable. A list value repeats
// its key once per element; null, false and other values are left out.
//   enc.query_encode({b: "x y!", a: 1})   // "a=1&b=x+y%21"
func m.query_encode(t){}

// query_decode([s]) -> a table of the pairs of a form query string. A
// leading "?" is skipped, a repeated key keeps its last value and a pair
// that does not decode is skipped; null gives {}.
//   enc.query_decode("a=1&b=x+y%21&flag")   // {a: "1", b: "x y!", flag: ""}
func m.query_decode(s){}

// ------------------------------------------------------------ checks

// utf8_valid(s) -> whether s is valid UTF-8
func m.utf8_valid(s){}

// crc32(s) -> the CRC-32 checksum of s, as an int
func m.crc32(s){}

// sha256(s) -> the SHA-256 digest of s: 32 raw bytes (hex_encode them for
// text)
func m.sha256(s){}

// mask(data, key) -> data XOR key repeated (WebSocket masking; the same
// call unmasks). Raises an error for an empty key.
func m.mask(data, key){}

return m
