// slang/encoding: base64, hex, percent-encoding, query strings
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
    local vectors = {
      {"", ""}, {"f", "Zg=="}, {"fo", "Zm8="}, {"foo", "Zm9v"},
      {"foob", "Zm9vYg=="}, {"fooba", "Zm9vYmE="}, {"foobar", "Zm9vYmFy"}
    }
    for(let local v in values(vectors)){
      assert(e.base64.encode(v[0]) == v[1], v[1])
      assert(e.base64.decode(v[1]) == v[0], v[1])
    }
    local bytes = "\x00\x01\xfe\xff\x80"
    assert(e.base64.decode(e.base64.encode(bytes)) == bytes)
    assert(e.base64.decode("Zm9vYg") == "foob", "padding is optional")
  }
  t.test("base64 rejects malformed input"){
    assert(e.base64.decode("Zm9v!") == null, "bad character")
    assert(e.base64.decode("Z") == null, "a lone character")
    assert(e.base64.decode("Zm9vYg=") == null, "padding to the wrong length")
    assert(e.base64.decode("Zm9vYg===") == null, "too much padding")
    assert(e.base64.decode("Zm-_") == null, "url alphabet")
  }
  t.test("base64url: url alphabet, padding off by default"){
    assert(e.base64url.encode("\xfb\xff") == "-_8")
    assert(e.base64url.encode("\xfb\xff", true) == "-_8=")
    assert(e.base64url.decode("-_8") == "\xfb\xff")
    assert(e.base64url.decode("-_8=") == "\xfb\xff")
    assert(e.base64url.decode("+/8") == null, "standard alphabet")
    // a JWT header
    assert(e.base64url.decode("eyJhbGciOiJIUzI1NiJ9") == "{\"alg\":\"HS256\"}")
  }
  t.test("hex"){
    assert(e.hex.encode("\x00\xffA") == "00ff41")
    assert(e.hex.decode("00FF41") == "\x00\xffA", "either case")
    assert(e.hex.decode("") == "")
    assert(e.hex.decode("0") == null, "odd length")
    assert(e.hex.decode("0g") == null, "not hex")
  }
  t.test("url_encode escapes all but the unreserved characters"){
    assert(e.url.encode("AZaz09-._~") == "AZaz09-._~")
    assert(e.url.encode("a b/?&=+%") == "a%20b%2F%3F%26%3D%2B%25")
    assert(e.url.encode("caf\u{e9}") == "caf%C3%A9", "UTF-8 bytes")
    assert(e.url.decode("caf%c3%a9") == "caf\u{e9}", "either case")
    assert(e.url.decode("a+b%20c") == "a+b c", "+ stays + in a URL")
    assert(
      e.url.decode("100%") == null and e.url.decode("%zz") == null and
        e.url.decode("%4") == null,
    )
  }
  t.test("form_encode writes a space as +"){
    assert(e.form.encode("a b&c") == "a+b%26c")
    assert(e.form.decode("a+b%2Bc") == "a b+c")
    assert(e.form.decode(e.form.encode("x + y = z?")) == "x + y = z?")
  }
  t.test("query_decode"){
    local q = e.query.decode("?a=1&b=x+y%21&flag&=skip&bad=%z&a=2&&c=")
    assert(q.a == "2", "the last value wins")
    assert(q.b == "x y!")
    assert(q.flag == "", "a key without a value")
    assert(q.c == "")
    assert(q.bad == null, "a malformed pair is skipped")
    assert(count(q) == 4)
    assert(count(e.query.decode(null)) == 0 and count(e.query.decode("")) == 0)
  }
  t.test("query_encode"){
    assert(
      e.query.encode({b: "x y!", a: 1, t: true, f: false, n: 1.5}) ==
        "a=1&b=x+y%21&n=1.5&t=true",
      "sorted, false left out",
    )
    assert(
      e.query.encode({tag: {"a", "b c"}}) == "tag=a&tag=b+c",
      "a list repeats its key",
    )
    assert(e.query.encode({}) == "")
    local q = e.query.decode(e.query.encode({["a&b"]: "c=d", ["\u{e9}"]: "?"}))
    assert(q["a&b"] == "c=d" and q["\u{e9}"] == "?")
  }
  t.test("argument errors"){
    local r = pcall(e.base64.encode, 1)
    assert(r[0] == "err")
  }
}

t.group("string escapes"){
  t.test("\\x is a byte, \\u{...} a code point in UTF-8"){
    local str = require("slang/string")
    assert(len("\x00\x7f\x80\xff") == 4)
    assert(str.byte_at("\xFF", 0) == 255 and "\x41\x62" == "Ab")
    assert(
      "\u{41}" == "A" and "\u{e9}" == "\xc3\xa9" and
        "\u{1F600}" == "\xf0\x9f\x98\x80",
    )
    assert("\u{10FFFF}" == "\xf4\x8f\xbf\xbf")
  }
  t.test("malformed escapes are compile errors at the string"){
    local cases = {
      {"\"\\q\"", "Invalid escape sequence \\q"},
      {"\"\\x4\"", "\\x needs two hex digits"},
      {"\"\\xg0\"", "\\x needs two hex digits"},
      {"\"\\u41\"", "\\u needs"},
      {"\"\\u{}\"", "\\u needs"},
      {"\"\\u{d800}\"", "\\u needs"},
      {"\"\\u{110000}\"", "\\u needs"},
      {"\"\\u{1234567}\"", "\\u needs"},
    }
    local str = require("slang/string")
    for(let local c in values(cases)){
      local r = pcall(
        compile, concat("local a = 1\nlocal s = ", c[0], "\n"), "escapes"
      )
      assert(r[0] == "err", c[0])
      assert(
        str.index_of(r[1].message, c[1]) >= 0,
        concat(c[0], ": ", r[1].message),
      )
      assert(
        r[1].location != null and r[1].location.line == 2,
        concat(c[0], " is located"),
      )
    }
  }
  t.test("expand writes bytes back as escapes"){
    local compiler = require("slang/compiler")
    local ast = require("slang/ast")
    local s = "a\x00\x1b\x7fz caf\u{e9}"
    assert(
      ast.to_string(ast.node("String", {value: s}, null)) ==
        "\"a\\x00\\x1b\\x7fz caf\u{e9}\"",
      "UTF-8 stays as it is",
    )
    assert(
      ast.to_string(ast.node("String", {value: "\xff\u{e9}"}, null)) ==
        "\"\\xff\\xc3\\xa9\"",
      "a string that is not UTF-8 escapes every high byte",
    )
  }
  t.test("binary round trips slang data"){
    local b = e.binary
    local v = {
      1, 223, 224, -1, 300, 9223372036854775807, -9223372036854775807 - 1,
      1.5, 0.1, "", "text", true, false, {x: 1, y: {2, 3}, [7]: "seven"},
    }
    local back = b.decode(b.encode(v))
    assert(string(back) == string(v), string(back))
    assert(type(back[7]) == "double" and back[7] == 1.5)
    assert(b.decode(b.encode(null)) == null)
    assert(len(b.encode(7)) == 1, "a small int is one byte")
    assert(len(b.encode(1.5)) == 5, "a float that fits 32 bits is five")
    assert(len(b.encode(0.1)) == 9)
  }
  t.test("binary raises on what it cannot encode or decode"){
    local b = e.binary
    assert(pcall(b.encode, print)[0] == "err")
    assert(pcall(b.encode, {f: print})[0] == "err")
    for(let local bad in values({"", "\x07\x05", "\x06\x09ab", "\x03\xff", "\x21\x21", "\x07\x01\x00\x00", "\x1f"})){
      assert(pcall(b.decode, bad)[0] == "err", e.hex.encode(bad))
    }
    local deep = {}
    for(local i = 0; i < 100; i = i + 1){
      deep = {deep}
    }
    assert(pcall(b.encode, deep)[0] == "err", "too deep")
  }
}
