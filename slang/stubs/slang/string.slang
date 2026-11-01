// slang/string: functions on byte strings, built into the VM.
//
//   local str = require("slang/string")
//   local parts = str.split("a, b, c", ", ")    // {"a", "b", "c"}
//   str.join(parts, "-")                       // "a-b-c"
//   str.substring("hello", 1, 3)               // "el"
//   str.format("%-6s|%5.2f", "pi", 3.14159)    // "pi    | 3.14"
//
// Strings are byte strings (UTF-8 by convention); positions are byte
// offsets from 0, and ranges include their start but not their end.
// slang/utf8 works with characters, slang/regex with patterns. `s * n`
// repeats a string n times.
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

// from_bytes(bytes: {int}) -> string
// A string from a list of byte values (ints 0-255). Raises an error for
// any other element.
func m.from_bytes(bytes){}

// to_bytes(s: string) -> {int}
// The bytes of s as a list of ints 0-255.
func m.to_bytes(s){}

// ------------------------------------------------------------ searching

// index_of(s: string, part: string, from?: int) -> int
// The offset of the first part at or after from (0 by default), or -1.
func m.index_of(s, part, from){}

// last_index_of(s: string, part: string, from?: int) -> int
// The offset of the last part that starts at or before from (the end of s
// by default), or -1.
func m.last_index_of(s, part, from){}

// contains(s: string, part: string) -> bool
// Whether part occurs in s.
func m.contains(s, part){}

// count(s: string, part: string) -> int
// The number of non-overlapping parts in s; an empty part counts the
// characters of s plus one.
func m.count(s, part){}

// starts_with(s: string, prefix: string, at?: int) -> bool
// Whether s has prefix at offset at (0 by default).
func m.starts_with(s, prefix, at){}

// ends_with(s: string, suffix: string) -> bool
// Whether s ends with suffix.
func m.ends_with(s, suffix){}

// compare(a: string, b: string) -> int
// -1, 0 or 1 as a sorts before, equal to or after b, byte by byte.
func m.compare(a, b){}

// equal_fold(a: string, b: string) -> bool
// Whether a and b are equal ignoring ASCII case.
func m.equal_fold(a, b){}

// ------------------------------------------------------------ splitting and joining

// join(list: {string}, sep?: string) -> string
// The strings of list joined with sep (" " by default). Raises an error
// for an element that is not a string.
func m.join(list, sep){}

// split(s: string, sep: string, n?: int) -> {string}
// The parts of s between the occurrences of sep; an empty sep splits s
// into its UTF-8 characters. With n > 0 there are at most n parts, the
// last one the rest of s; n = 0 gives none.
//   str.split("a,b,c", ",", 2)   // {"a", "b,c"}
func m.split(s, sep, n){}

// cut(s: string, sep: string) -> {string}?
// {before, after}: s around the first sep, or null when sep is not in s.
//   if(let {local k, local v} = str.cut(line, "=")){ ... }
func m.cut(s, sep){}

// fields(s: string) -> {string}
// The parts of s between runs of whitespace; none for blank s.
func m.fields(s){}

// lines(s: string) -> {string}
// The lines of s without their line endings ("\n" or "\r\n"). A line
// ending at the very end does not start another line.
func m.lines(s){}

// ------------------------------------------------------------ transforming

// trim(s: string, cutset?: string) -> string
// s without leading and trailing (Unicode) whitespace, or without the
// characters of cutset when it is given.
func m.trim(s, cutset){}

// trim_start(s: string, cutset?: string) -> string
// Like [trim], at the start only.
func m.trim_start(s, cutset){}

// trim_end(s: string, cutset?: string) -> string
// Like [trim], at the end only.
func m.trim_end(s, cutset){}

// trim_prefix(s: string, prefix: string) -> string
// s without prefix when it starts with it; s otherwise.
func m.trim_prefix(s, prefix){}

// trim_suffix(s: string, suffix: string) -> string
// s without suffix when it ends with it; s otherwise.
func m.trim_suffix(s, suffix){}

// upper(s: string) -> string
// s with the ASCII letters in upper case.
func m.upper(s){}

// lower(s: string) -> string
// s with the ASCII letters in lower case.
func m.lower(s){}

// replace(s: string, old: string, new: string, n?: int) -> string
// s with every old (the first n, when n is given and not negative)
// replaced by new; an empty old returns s unchanged.
func m.replace(s, old, new, n){}

// xor(data: string, key: string) -> string
// The bytes of data XOR the bytes of key, repeated: WebSocket masking, and
// the same call undoes it. Raises an error for an empty key.
func m.xor(data, key){}

// ------------------------------------------------------------ numbers and formatting

// format(fmt: string, ...values) -> string
// The values formatted by the verbs of fmt, printf style after Go's fmt:
// `%v` any value as [string] renders it, `%s` a string, `%q` a quoted
// string, `%d` an int (or a double without fraction), `%x %X %o %b` an int
// in base 16, 8 or 2 as an unsigned 64-bit number (`%x` of a string gives
// the hex of its bytes), `%c` the character of a code point, `%t` a bool,
// `%f %e %g` (and `%F %E %G`) a number as a double, `%%` a percent sign.
// Flags: `-` pads on the right, `+` writes a sign, a space leaves room for
// one, `0` pads numbers with zeros, `#` adds 0x/0/0b. A width and a
// precision (`%8.3f`) may be `*`, taken from the values. Width counts
// characters; the precision of `%s` is the most characters to keep, of
// `%d` the fewest digits, of `%f` and `%e` the digits after the point (6
// by default) and of `%g` the significant digits. Raises an error for an
// unknown verb, a value of the wrong type, or too few or too many values.
//   str.format("%-8s%6.2f", "total", 12.5)   // "total    12.50"
//   str.format("%04d-%02d", 2026, 3)          // "2026-03"
//   str.format("%x", hash.sha256(s))          // the digest as hex
func m.format(fmt, ...values){}

// to_number(s: string) -> int | float | null
// s parsed as a decimal int, else as a double, or null when it is
// neither.
func m.to_number(s){}

// parse_int(s: string, base?: int) -> int?
// s as an int in base (10 by default, 2 to 36) with an optional sign, or
// null when it is not one or does not fit. Base 0 reads a 0x, 0o or 0b
// prefix.
//   str.parse_int("ff", 16)    // 255
//   str.parse_int("0b101", 0)  // 5
func m.parse_int(s, base){}

// ------------------------------------------------------------ lines and columns

// line_starts(s: string) -> {int}
// The offsets at which the lines of s start; the first is 0.
func m.line_starts(s){}

// line_col(s: string, pos: int) -> {int}
// {line, column} of offset pos, both counting from 1 (the column in
// bytes).
func m.line_col(s, pos){}

return m
