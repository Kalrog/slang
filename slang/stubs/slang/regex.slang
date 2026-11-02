// slang/regex: regular expressions, built into the VM.
//
//   local regex = require("slang/regex")
//   local kv = regex.compile("(?P<key>\\w+)=(\\d+)")
//   kv:matches("a=1")                        // true
//   local m = kv:find("x a=1")               // m.text "a=1", m.groups[1] "a"
//   kv:replace("a=1 b=2", "$key:$2")         // "a:1 b:2"
//   regex.compile("\\s*,\\s*"):split("a , b,c")   // {"a", "b", "c"}
//
// The syntax is RE2's, as in Go: `.` `[a-z]` `[^...]` `[[:alpha:]]`
// `\d \w \s` (and `\D \W \S`, all ASCII), `^ $ \A \z \b \B`, groups `(...)`,
// `(?:...)`, `(?P<name>...)` or `(?<name>...)`, `| * + ? {n} {n,} {n,m}`,
// lazy forms `*? +? ?? {n,m}?`, escapes `\n \t \x41 \x{263a} \Q...\E`, and
// flags `(?i)` (ASCII case folding), `(?m)` (^ and $ at lines), `(?s)` (.
// matches \n) and `(?U)` (lazy by default), also scoped as `(?i:...)`.
// There are no backreferences or lookaround, so a match takes time linear
// in the length of the input. Matching is leftmost-first, as in Perl and
// Go. Positions are byte offsets; `.` and classes match one UTF-8
// character.
local m = {}

// A compiled pattern, from [compile]; type() of it is "regex", and
// string(re) is "regex(<pattern>)".
// type Regex
// [pattern]: the source of the pattern
// [group_names]: the name of each group by number: index 0 (the whole
//   match) and unnamed groups are ""
local regex_methods = {}
local regex_meta = {__index: regex_methods, __type: "regex"}

// A match, from [Regex.find] and [Regex.find_all].
// type Match = {text: string, start: int, end: int, groups: {string},
//   spans: {{int}}, named: {[string]: string}}
// [text]: the matched text, s from start up to end
// [groups]: the text of each group by number, the whole match at 0; "" for
//   a group that took no part
// [spans]: {start, end} of each group by number; {-1, -1} for one that
//   took no part
// [named]: the text of each named group that took part

// compile(pattern: string) -> Regex
// Compiles a pattern; raises "regex: <problem> at offset <n> in
// `<pattern>`" for a syntax error.
func m.compile(pattern){
  return {meta: regex_meta}
}

// escape(s: string) -> string
// s with every metacharacter escaped, for a pattern matching s literally.
func m.escape(s){}

// matches(s: string) -> bool
// Whether the pattern matches anywhere in s.
func regex_methods.matches(self, s){}

// match_at(s: string, pos?: int) -> int
// The end of a match that starts exactly at pos (0 by default), or -1.
// Allocates nothing: the call for scanners and lexers.
//   regex.compile("[a-z_]\\w*"):match_at("x1 = 2", 0)   // 2
func regex_methods.match_at(self, s, pos){}

// find(s: string, from?: int) -> Match?
// The leftmost match at or after offset from (0 by default), or null.
// `^` and `\b` still see the text before from.
func regex_methods.find(self, s, from){}

// find_all(s: string, n?: int) -> {Match}
// The successive non-overlapping matches (at most n). An empty match right
// after a match is skipped.
func regex_methods.find_all(self, s, n){}

// replace(s: string, repl: string | func(m: Match): string, n?: int) -> string
// s with its matches (the first n) replaced. A string repl expands `$1`,
// `${1}`, `$name` and `${name}` to the group's text and `$$` to `$`; a
// function gets the [Match] and returns the replacement.
//   regex.compile("(\\w+)@(\\w+)"):replace("me@host", "$2 at $1")   // "host at me"
func regex_methods.replace(self, s, repl, n){}

// split(s: string, n?: int) -> {string}
// The parts of s between the matches; with n > 0 at most n parts, the
// last one the rest of s.
func regex_methods.split(self, s, n){}


return m
