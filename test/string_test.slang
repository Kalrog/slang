// slang/string: searching, splitting, trimming, formatting
local t = require("slang/test")
local str = require("slang/string")

t.group("string"){
  t.test("searching"){
    assert(str.index_of("a.b.c", ".") == 1 and str.last_index_of("a.b.c", ".") == 3)
    assert(str.last_index_of("a.b.c", ".", 2) == 1, "at or before from")
    assert(str.last_index_of("abc", "x") == -1 and str.last_index_of("abc", "") == 3)
    assert(str.contains("hello", "ell") and not str.contains("hello", "x"))
    assert(str.count("cheese", "e") == 3 and str.count("aaaa", "aa") == 2)
    assert(str.count("h\u{e9}", "") == 3, "characters plus one")
    assert(str.equal_fold("Go", "GO") and not str.equal_fold("go", "gx"))
  }
  t.test("splitting"){
    assert(str.split("a,b,c", ",") == {"a", "b", "c"})
    assert(str.split("a,b,c", ",", 2) == {"a", "b,c"}, "at most n parts")
    assert(str.split("a,b", ",", 0) == {})
    assert(str.split("ab", "") == {"a", "b"})
    assert(str.cut("k=v=w", "=") == {"k", "v=w"} and str.cut("kv", "=") == null)
    assert(str.fields("  a b\t\n c  ") == {"a", "b", "c"} and str.fields(" ") == {})
    assert(str.lines("x\r\ny\n\nz") == {"x", "y", "", "z"})
    assert(str.lines("x\n") == {"x"} and str.lines("") == {})
  }
  t.test("trimming and replacing"){
    assert(str.trim("  hi \n") == "hi" and str.trim("xxhixx", "x") == "hi")
    assert(str.trim_start("  hi  ") == "hi  " and str.trim_end("  hi  ") == "  hi")
    assert(str.trim_start("abcab", "ba") == "cab")
    assert(str.trim_prefix("foobar", "foo") == "bar" and str.trim_prefix("bar", "foo") == "bar")
    assert(str.trim_suffix("foobar", "bar") == "foo")
    assert(str.replace("aaaa", "a", "b") == "bbbb" and str.replace("aaaa", "a", "b", 2) == "bbaa")
    assert(str.xor(str.xor("bytes \x00\xff", "\x37\xfa"), "\x37\xfa") == "bytes \x00\xff")
    // RFC 6455, 5.7: "Hello" masked
    assert(str.xor("Hello", "\x37\xfa\x21\x3d") == "\x7f\x9f\x4d\x51\x58")
    assert(pcall(str.xor, "x", "")[0] == "err")
    assert(str.to_bytes("hi") == {104, 105} and str.from_bytes({104, 105}) == "hi")
  }
  t.test("numbers"){
    assert(str.parse_int("42") == 42 and str.parse_int("-17") == -17)
    assert(str.parse_int("ff", 16) == 255 and str.parse_int("0x1F", 0) == 31)
    assert(str.parse_int("0b101", 0) == 5 and str.parse_int("0o17", 0) == 15)
    assert(str.parse_int("x") == null and str.parse_int("") == null)
    assert(str.parse_int("9223372036854775808") == null, "overflow")
    assert(str.parse_int("-9223372036854775808") < 0)
    assert(str.to_number("2.5") == 2.5 and str.to_number("x") == null)
  }
  t.test("format"){
    assert(str.format("%d|%5d|%-5d|%05d", 1, 2, 3, -4) == "1|    2|3    |-0004")
    assert(str.format("%s and %v", "a", {1}) == "a and {0: 1}")
    assert(str.format("%x %X %#x %o %b", 255, 255, 255, 8, 5) == "ff FF 0xff 10 101")
    assert(str.format("%x", -1) == "ffffffffffffffff", "as an unsigned number")
    assert(str.format("%x", "hi") == "6869", "the bytes of a string")
    assert(str.format("%.2f|%8.3f|%e|%g", 3.14159, 2.5, 1234.5, 0.0001) ==
      "3.14|   2.500|1.234500e+03|0.0001")
    assert(str.format("%g %g %.3g", 100.0, 1e21, 3.14159) == "100 1e+21 3.14")
    assert(str.format("%q", "a\"b\n") == "\"a\\\"b\\n\"")
    assert(str.format("%c%c %t %%", 104, 233, true) == "h\u{e9} true %")
    assert(str.format("%*d|%-*s|", 4, 7, 3, "a") == "   7|a  |")
    assert(str.format("%.2s|%5s", "h\u{e9}llo", "\u{e9}") == "h\u{e9}|    \u{e9}", "characters, not bytes")
    assert(str.format("%d", 2.0) == "2", "a double without fraction")
    assert(pcall(str.format, "%d", 2.5)[0] == "err")
    assert(pcall(str.format, "%d")[0] == "err", "a missing argument")
    assert(pcall(str.format, "%d", 1, 2)[0] == "err", "an extra argument")
    assert(pcall(str.format, "%y", 1)[0] == "err", "an unknown verb")
  }
}
