// slang/encoding: the byte encodings web code needs, built into the VM,
// one table per encoding with an encode and a decode.
//
//   local enc = require("slang/encoding")
//   enc.base64.encode("hi!")                     // "aGkh"
//   enc.hex.encode("\x01\xff")                   // "01ff"
//   enc.query.encode({q: "slang lang", page: 2}) // "page=2&q=slang+lang"
//   enc.url.decode("a%20b")                      // "a b"
//
// Strings are byte strings, so every encoder takes any bytes. Decoders
// return null on malformed input instead of raising (untrusted input is
// the normal case). Checksums are in slang/hash, characters in slang/utf8.
local m = {}

// An encoding: encode(s) gives the encoded text, decode(s) the bytes
// back, or null when s is not valid.
// type Codec = {encode: func(s: string): string, decode: func(s: string): string?}

// Standard base64 (RFC 4648), a [Codec]: encode writes "=" padding, decode
// accepts text with or without it.
//   enc.base64.decode("aGkh")   // "hi!"
m.base64 = {encode: func(s){}, decode: func(s){}}

// URL-safe base64 ("-" and "_" for "+" and "/"), as JWTs use it, a
// [Codec]: encode(s, pad?) leaves the padding off unless pad is true,
// decode accepts either form.
m.base64url = {encode: func(s, pad){}, decode: func(s){}}

// Hex digits, a [Codec]: encode writes two lower-case digits per byte,
// decode reads either case.
m.hex = {encode: func(s){}, decode: func(s){}}

// Percent-encoding of a URI component (RFC 3986), a [Codec]: encode escapes
// everything but A-Z a-z 0-9 - . _ ~; decode fails when a "%" is not
// followed by two hex digits.
m.url = {encode: func(s){}, decode: func(s){}}

// Form encoding (application/x-www-form-urlencoded), a [Codec]: [url] with
// a space as "+".
m.form = {encode: func(s){}, decode: func(s){}}

// Form query strings. encode(t) writes the string, number and boolean
// fields of t in key order, so the result is stable; a list value repeats
// its key once per element, and null, false and other values are left
// out. decode(s?) gives the pairs as a table: a leading "?" is skipped, a
// repeated key keeps its last value, a pair that does not decode is
// skipped, and null gives {}.
//   enc.query.encode({b: "x y!", a: 1})      // "a=1&b=x+y%21"
//   enc.query.decode("a=1&b=x+y%21&flag")    // {a: "1", b: "x y!", flag: ""}
m.query = {encode: func(t){}, decode: func(s){}}

// A compact byte form of slang data, for files and the network. encode(v)
// takes null, booleans, numbers, strings and tables of them (metatables
// are left out) and raises for anything else; small ints take one byte, a
// float a 32-bit float holds exactly five. decode(s) gives the value back
// and raises when s is not one whole value (null is a valid result).
//   enc.binary.decode(enc.binary.encode({x: 1.5, tags: {"a"}}))  // {x: 1.5, tags: {"a"}}
m.binary = {encode: func(v){}, decode: func(s){}}

return m
