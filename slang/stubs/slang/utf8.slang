// slang/utf8: the characters of UTF-8 strings, built into the VM.
// slang/string works on bytes; this module decodes and encodes code
// points.
//
//   local utf8 = require("slang/utf8")
//   utf8.count("héllo")       // 5 (len gives 6, the bytes)
//   utf8.char(233)            // "é"
//   utf8.code_at("é", 0)      // 233
//
// An invalid byte counts as one character, U+FFFD, as in Go. str.split(s,
// "") gives the characters of s as a list.
local m = {}

// valid(s: string) -> bool
// Whether s is valid UTF-8.
func m.valid(s){}

// count(s: string) -> int
// The number of characters of s.
func m.count(s){}

// char(code: int) -> string
// The UTF-8 encoding of the code point; an invalid code point gives
// U+FFFD.
func m.char(code){}

// code_at(s: string, pos?: int) -> int?
// The code point of the character at offset pos (0 by default), or null
// out of range.
func m.code_at(s, pos){}

// size_at(s: string, pos?: int) -> int
// The byte length of the character at offset pos (0 by default), or 0 at
// the end.
func m.size_at(s, pos){}

// utf16_len(s: string) -> int
// The number of UTF-16 code units of s (what LSP positions count): one per
// code point, two above U+FFFF.
func m.utf16_len(s){}

return m
