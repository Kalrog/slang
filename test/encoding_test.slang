// slang/encoding: base64, hex, percent-encoding, query strings, checks
local t = require("slang/test")
local e = require("slang/encoding")

local func count(t){
  local n = 0
  for(let local k in keys(t)){
    n = n + 1
  }
  return n
}

t.group("encoding"){
  t.test("base64 round trips any bytes"){
    // RFC 4648 test vectors
    local vectors = {{"", ""}, {"f", "Zg=="}, {"fo", "Zm8="}, {"foo", "Zm9v"},
                     {"foob", "Zm9vYg=="}, {"fooba", "Zm9vYmE="}, {"foobar", "Zm9vYmFy"}}
    for(let local v in values(vectors)){
      assert(e.base64_encode(v[0]) == v[1], v[1])
      assert(e.base64_decode(v[1]) == v[0], v[1])
    }
    local bytes = "\x00\x01\xfe\xff\x80"
    assert(e.base64_decode(e.base64_encode(bytes)) == bytes)
    assert(e.base64_decode("Zm9vYg") == "foob", "padding is optional")
  }
  t.test("base64 rejects malformed input"){
    assert(e.base64_decode("Zm9v!") == null, "bad character")
    assert(e.base64_decode("Z") == null, "a lone character")
    assert(e.base64_decode("Zm9vYg=") == null, "padding to the wrong length")
    assert(e.base64_decode("Zm9vYg===") == null, "too much padding")
    assert(e.base64_decode("Zm-_") == null, "url alphabet")
  }
  t.test("base64url: url alphabet, padding off by default"){
    assert(e.base64url_encode("\xfb\xff") == "-_8")
    assert(e.base64url_encode("\xfb\xff", true) == "-_8=")
    assert(e.base64url_decode("-_8") == "\xfb\xff")
    assert(e.base64url_decode("-_8=") == "\xfb\xff")
    assert(e.base64url_decode("+/8") == null, "standard alphabet")
    // a JWT header
    assert(e.base64url_decode("eyJhbGciOiJIUzI1NiJ9") == "{\"alg\":\"HS256\"}")
  }
  t.test("hex"){
    assert(e.hex_encode("\x00\xffA") == "00ff41")
    assert(e.hex_decode("00FF41") == "\x00\xffA", "either case")
    assert(e.hex_decode("") == "")
    assert(e.hex_decode("0") == null, "odd length")
    assert(e.hex_decode("0g") == null, "not hex")
  }
  t.test("url_encode escapes all but the unreserved characters"){
    assert(e.url_encode("AZaz09-._~") == "AZaz09-._~")
    assert(e.url_encode("a b/?&=+%") == "a%20b%2F%3F%26%3D%2B%25")
    assert(e.url_encode("caf\u{e9}") == "caf%C3%A9", "UTF-8 bytes")
    assert(e.url_decode("caf%c3%a9") == "caf\u{e9}", "either case")
    assert(e.url_decode("a+b%20c") == "a+b c", "+ stays + in a URL")
    assert(e.url_decode("100%") == null and e.url_decode("%zz") == null and e.url_decode("%4") == null)
  }
  t.test("form_encode writes a space as +"){
    assert(e.form_encode("a b&c") == "a+b%26c")
    assert(e.form_decode("a+b%2Bc") == "a b+c")
    assert(e.form_decode(e.form_encode("x + y = z?")) == "x + y = z?")
  }
  t.test("query_decode"){
    local q = e.query_decode("?a=1&b=x+y%21&flag&=skip&bad=%z&a=2&&c=")
    assert(q.a == "2", "the last value wins")
    assert(q.b == "x y!")
    assert(q.flag == "", "a key without a value")
    assert(q.c == "")
    assert(q.bad == null, "a malformed pair is skipped")
    assert(count(q) == 4)
    assert(count(e.query_decode(null)) == 0 and count(e.query_decode("")) == 0)
  }
  t.test("query_encode"){
    assert(e.query_encode({b: "x y!", a: 1, t: true, f: false, n: 1.5}) == "a=1&b=x+y%21&n=1.5&t=true",
           "sorted, false left out")
    assert(e.query_encode({tag: {"a", "b c"}}) == "tag=a&tag=b+c", "a list repeats its key")
    assert(e.query_encode({}) == "")
    local q = e.query_decode(e.query_encode({["a&b"]: "c=d", ["\u{e9}"]: "?"}))
    assert(q["a&b"] == "c=d" and q["\u{e9}"] == "?")
  }
  t.test("utf8_valid and crc32"){
    assert(e.utf8_valid("") and e.utf8_valid("caf\u{e9} \u{1F600}"))
    assert(not e.utf8_valid("\xff") and not e.utf8_valid("\xc3"), "invalid and truncated")
    assert(not e.utf8_valid("\xed\xa0\x80"), "an encoded surrogate")
    assert(e.crc32("") == 0)
    assert(e.crc32("The quick brown fox jumps over the lazy dog") == 1095738169)
  }
  t.test("argument errors"){
    local r = pcall(e.base64_encode, 1)
    assert(r[0] == "err")
  }
}

t.group("string escapes"){
  t.test("\\x is a byte, \\u{...} a code point in UTF-8"){
    local str = require("slang/string")
    assert(len("\x00\x7f\x80\xff") == 4)
    assert(str.byte_at("\xFF", 0) == 255 and "\x41\x62" == "Ab")
    assert("\u{41}" == "A" and "\u{e9}" == "\xc3\xa9" and "\u{1F600}" == "\xf0\x9f\x98\x80")
    assert("\u{10FFFF}" == "\xf4\x8f\xbf\xbf")
  }
  t.test("malformed escapes are compile errors at the string"){
    local cases = {{"\"\\q\"", "Invalid escape sequence \\q"}, {"\"\\x4\"", "\\x needs two hex digits"},
                   {"\"\\xg0\"", "\\x needs two hex digits"}, {"\"\\u41\"", "\\u needs"},
                   {"\"\\u{}\"", "\\u needs"}, {"\"\\u{d800}\"", "\\u needs"},
                   {"\"\\u{110000}\"", "\\u needs"}, {"\"\\u{1234567}\"", "\\u needs"}}
    local str = require("slang/string")
    for(let local c in values(cases)){
      local r = pcall(compile, concat("local a = 1\nlocal s = ", c[0], "\n"), "escapes")
      assert(r[0] == "err", c[0])
      assert(str.index_of(r[1].message, c[1]) >= 0, concat(c[0], ": ", r[1].message))
      assert(r[1].location != null and r[1].location.line == 2, concat(c[0], " is located"))
    }
  }
  t.test("expand writes bytes back as escapes"){
    local compiler = require("slang/compiler")
    local ast = require("slang/ast")
    local s = "a\x00\x1b\x7fz caf\u{e9}"
    assert(ast.to_string(ast.node("String", {value: s}, null)) == "\"a\\x00\\x1b\\x7fz caf\u{e9}\"",
           "UTF-8 stays as it is")
    assert(ast.to_string(ast.node("String", {value: "\xff\u{e9}"}, null)) == "\"\\xff\\xc3\\xa9\"",
           "a string that is not UTF-8 escapes every high byte")
  }
}
