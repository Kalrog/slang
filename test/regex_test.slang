// slang/regex: RE2 syntax, leftmost-first matching, linear time
local t = require("slang/test")
local regex = require("slang/regex")
local str = require("slang/string")

t.group("regex"){
  t.test("matches and match_at"){
    assert(regex.compile("^\\d{3}-\\d{4}$"):matches("555-1234"))
    assert(not regex.compile("^\\d{3}$"):matches("5555"))
    local word = regex.compile("[a-z]+")
    assert(word:match_at("abc1", 0) == 3 and word:match_at("1abc", 0) == -1)
    assert(word:match_at("1abc", 1) == 4 and word:match_at("abc", 9) == -1)
    assert(regex.compile("(?i)hello"):matches("HeLLo"))
    assert(regex.compile("[^\"]*"):match_at("h\u{e9}llo\"x", 0) == 6, "characters")
    assert(regex.compile("(?m)^b$"):find("a\nb\nc").start == 2)
    assert(regex.compile("\\bfoo\\b"):find("a foo b").start == 2)
    assert(regex.compile("[[:alpha:]]+"):find("12abc3").text == "abc")
  }
  t.test("find and groups"){
    local r = regex.compile("(?P<key>\\w+)=(\\d+)")
    local m = r:find("x a=1 bb=22")
    assert(m.text == "a=1" and m.start == 2 and m["end"] == 5)
    assert(m.groups == {"a=1", "a", "1"} and m.named.key == "a")
    assert(m.spans[2] == {4, 5})
    assert(r:find("x a=1 bb=22", 5).text == "bb=22", "from a position")
    assert(r:find("nothing") == null)
    assert(len(r:find_all("a=1 bb=22 c=x")) == 2)
    assert(r:group_names() == {"", "key", ""})
    local opt = regex.compile("a(x)?b"):find("ab")
    assert(opt.groups[1] == "" and opt.spans[1] == {-1, -1}, "an unmatched group")
    // leftmost-first, as Perl and Go
    assert(regex.compile("(a|ab)(c|bcd)(d*)"):find("abcd").groups == {"abcd", "a", "bcd", ""})
    assert(regex.compile("x*?y"):find("xxy").text == "xxy")
    assert(regex.compile("a+?"):find("aaa").text == "a")
  }
  t.test("replace and split"){
    local r = regex.compile("(?P<key>\\w+)=(\\d+)")
    assert(r:replace("a=1 bb=22", "$2:${key}") == "1:a 22:bb")
    assert(r:replace("a=1 b=2", "[$0]", 1) == "[a=1] b=2")
    assert(r:replace("a=1", func(m){ return str.upper(m.groups[1]) }) == "A")
    assert(regex.compile("a*"):replace("baaac", "-") == "-b-c-")
    assert(regex.compile("\\s*,\\s*"):split("a , b,c") == {"a", "b", "c"})
    assert(regex.compile(""):split("abc") == {"a", "b", "c"})
    assert(regex.compile(","):split("a,b,c", 2) == {"a", "b,c"})
    assert(regex.compile(","):split("") == {""})
    assert(regex.escape("a.b*c") == "a\\.b\\*c")
    assert(regex.compile(regex.escape("1+1=2")):matches("1+1=2"))
  }
  t.test("errors and limits"){
    local e = pcall(regex.compile, "a(b")
    assert(e[0] == "err" and str.contains(e[1].message, "missing closing )"))
    assert(pcall(regex.compile, "a**")[0] == "err")
    assert(pcall(regex.compile, "\\1")[0] == "err", "no backreferences")
    assert(pcall(regex.compile, "a{1001}")[0] == "err")
    // nested repetition stays linear
    local m = regex.compile("(a*)*$"):find(concat("a" * 40, "b"))
    assert(m.start == 41)
  }
}
