// slang/string: string functions, built into the VM. Strings are byte
// strings (UTF-8 by convention); positions are byte offsets from 0.
local m = {}

// ------------------------------------------------------------ pieces

// substring(s, [start], [end]) -> the bytes of s from start (0 by default)
// up to, not including, end (the length of s by default). Raises an error
// when the range is out of bounds.
func m.substring(s, start, end){}

// byte_at(s, i) -> the byte at offset i as an int, or null out of range
func m.byte_at(s, i){}

// char_at(s, i) -> the UTF-8 character starting at offset i as a string,
// or null out of range
func m.char_at(s, i){}

// rune_len_at(s, pos) -> the byte length of the UTF-8 character at pos, or
// 0 at the end
func m.rune_len_at(s, pos){}

// chr(code) -> the UTF-8 encoding of the code point; an invalid code point
// gives U+FFFD
func m.chr(code){}

// from_bytes(bytes) -> a string from a list of byte values (ints 0-255).
// Raises an error for any other element.
func m.from_bytes(bytes){}

// utf16_len(s) -> the number of UTF-16 code units of s (what LSP positions
// count): one per code point, two above U+FFFF
func m.utf16_len(s){}

// ------------------------------------------------------------ searching

// index_of(s, part, [from]) -> the offset of the first part at or after
// from (0 by default), or -1
func m.index_of(s, part, from){}

// starts_with(s, prefix, [at]) -> whether s has prefix at offset at (0 by
// default)
func m.starts_with(s, prefix, at){}

// ends_with(s, suffix) -> whether s ends with suffix
func m.ends_with(s, suffix){}

// compare(a, b) -> -1, 0 or 1 as a sorts before, equal to or after b,
// byte by byte
func m.compare(a, b){}

// ------------------------------------------------------------ transforming

// join(list, [sep]) -> the strings of list joined with sep (" " by
// default). Raises an error for an element that is not a string.
func m.join(list, sep){}

// split(s, sep) -> the list of the parts of s between the occurrences of
// sep; an empty sep splits s into its UTF-8 characters
func m.split(s, sep){}

// trim(s) -> s without leading and trailing (Unicode) whitespace
func m.trim(s){}

// upper(s) -> s with the ASCII letters in upper case
func m.upper(s){}

// lower(s) -> s with the ASCII letters in lower case
func m.lower(s){}

// replace(s, old, new) -> s with every old replaced by new; an empty old
// returns s unchanged
func m.replace(s, old, new){}

// to_number(s) -> s parsed as a decimal int, else as a double, or null when
// it is neither
func m.to_number(s){}

// hash(s) -> a stable 64-bit hash of s (FNV-1a) as hex digits
func m.hash(s){}

// ------------------------------------------------------------ scanning

// char_class(spec) -> a compiled character class: single characters and
// ranges like `a-z`, negated by a leading `^`
//   local digit = str.char_class("0-9")
func m.char_class(spec){}

// class_match(class, s, [pos]) -> the byte length of the character at pos
// (0 by default) when it is in class, otherwise 0
func m.class_match(class, s, pos){}

// class_run(class, s, [pos]) -> the offset after the longest run of
// characters in class starting at pos (0 by default); pos when there is none
func m.class_run(class, s, pos){}

// space_at(s, pos) -> the byte length of the whitespace character at pos,
// or 0
func m.space_at(s, pos){}

// skip_space(s, [pos]) -> the offset after the whitespace and `//` line
// comments starting at pos (0 by default); a comment ends before its newline
func m.skip_space(s, pos){}

// ------------------------------------------------------------ lines

// line_starts(s) -> the list of offsets at which the lines of s start; the
// first is 0
func m.line_starts(s){}

// line_col(s, pos) -> {line, column} of offset pos, both counting from 1
// (the column in bytes)
func m.line_col(s, pos){}

return m
