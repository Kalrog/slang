// slang/string: string functions, built into the VM.
//
//   local str = require("slang/string")
//   local parts = str.split("a, b, c", ", ")    // {"a", "b", "c"}
//   str.join(parts, "-")                       // "a-b-c"
//   str.substring("hello", 1, 3)               // "el"
//   str.index_of("hello", "l")                 // 2
//
// Strings are byte strings (UTF-8 by convention); positions are byte
// offsets from 0, and ranges include their start but not their end. For
// scanning text quickly, [char_class] compiles a set of characters that
// [class_match] and [class_run] test against.

// A compiled set of characters, from [char_class]; type() of it is
// "userdata".
// type CharClass = any
local m = {}

// ------------------------------------------------------------ pieces

// substring(s: string, start?: int, end?: int) -> string
// The bytes of s from start (0 by default) up to, not including, end (the
// length of s by default). Raises an error when the range is out of
// bounds.
func m.substring(s, start, end){}

// byte_at(s: string, i: int) -> int?
// The byte at offset i, or null out of range.
func m.byte_at(s, i){}

// char_at(s: string, i: int) -> string?
// The UTF-8 character starting at offset i, or null out of range.
func m.char_at(s, i){}

// rune_len_at(s: string, pos: int) -> int
// The byte length of the UTF-8 character at pos, or 0 at the end.
func m.rune_len_at(s, pos){}

// chr(code: int) -> string
// The UTF-8 encoding of the code point; an invalid code point gives
// U+FFFD.
func m.chr(code){}

// from_bytes(bytes: {int}) -> string
// A string from a list of byte values (ints 0-255). Raises an error for
// any other element.
func m.from_bytes(bytes){}

// utf16_len(s: string) -> int
// The number of UTF-16 code units of s (what LSP positions count): one per
// code point, two above U+FFFF.
func m.utf16_len(s){}

// ------------------------------------------------------------ searching

// index_of(s: string, part: string, from?: int) -> int
// The offset of the first part at or after from (0 by default), or -1.
func m.index_of(s, part, from){}

// starts_with(s: string, prefix: string, at?: int) -> bool
// Whether s has prefix at offset at (0 by default).
func m.starts_with(s, prefix, at){}

// ends_with(s: string, suffix: string) -> bool
// Whether s ends with suffix.
func m.ends_with(s, suffix){}

// compare(a: string, b: string) -> int
// -1, 0 or 1 as a sorts before, equal to or after b, byte by byte.
func m.compare(a, b){}

// ------------------------------------------------------------ transforming

// join(list: {string}, sep?: string) -> string
// The strings of list joined with sep (" " by default). Raises an error
// for an element that is not a string.
func m.join(list, sep){}

// split(s: string, sep: string) -> {string}
// The parts of s between the occurrences of sep; an empty sep splits s
// into its UTF-8 characters.
func m.split(s, sep){}

// trim(s: string) -> string
// s without leading and trailing (Unicode) whitespace.
func m.trim(s){}

// upper(s: string) -> string
// s with the ASCII letters in upper case.
func m.upper(s){}

// lower(s: string) -> string
// s with the ASCII letters in lower case.
func m.lower(s){}

// replace(s: string, old: string, new: string) -> string
// s with every old replaced by new; an empty old returns s unchanged.
func m.replace(s, old, new){}

// to_number(s: string) -> int | float | null
// s parsed as a decimal int, else as a double, or null when it is
// neither.
func m.to_number(s){}

// hash(s: string) -> string
// A stable 64-bit hash of s (FNV-1a), as hex digits.
func m.hash(s){}

// ------------------------------------------------------------ scanning

// char_class(spec: string) -> CharClass
// Compiles a character class: single characters and ranges like `a-z`,
// negated by a leading `^`.
//   local digit = str.char_class("0-9")
func m.char_class(spec){}

// class_match(class: CharClass, s: string, pos?: int) -> int
// The byte length of the character at pos (0 by default) when it is in
// class, otherwise 0.
func m.class_match(class, s, pos){}

// class_run(class: CharClass, s: string, pos?: int) -> int
// The offset after the longest run of characters in class starting at pos
// (0 by default); pos when there is none.
func m.class_run(class, s, pos){}

// space_at(s: string, pos: int) -> int
// The byte length of the whitespace character at pos, or 0.
func m.space_at(s, pos){}

// skip_space(s: string, pos?: int) -> int
// The offset after the whitespace and `//` line comments starting at pos
// (0 by default); a comment ends before its newline.
func m.skip_space(s, pos){}

// ------------------------------------------------------------ lines

// line_starts(s: string) -> {int}
// The offsets at which the lines of s start; the first is 0.
func m.line_starts(s){}

// line_col(s: string, pos: int) -> {int}
// {line, column} of offset pos, both counting from 1 (the column in
// bytes).
func m.line_col(s, pos){}

return m
