// slang/utf8 and slang/hash
local t = require("slang/test")
local utf8 = require("slang/utf8")
local hash = require("slang/hash")
local str = require("slang/string")

t.group("utf8"){
  t.test("characters"){
    assert(utf8.valid("") and utf8.valid("caf\u{e9} \u{1F600}"))
    assert(not utf8.valid("\xff") and not utf8.valid("\xc3"), "invalid and truncated")
    assert(not utf8.valid("\xed\xa0\x80"), "an encoded surrogate")
    assert(utf8.count("h\u{e9}llo") == 5 and utf8.count("\xff\xff") == 2)
    assert(utf8.char(233) == "\u{e9}" and utf8.char(-1) == "\u{FFFD}")
    assert(utf8.code_at("\u{e9}", 0) == 233 and utf8.code_at("a", 5) == null)
    assert(utf8.size_at("\u{e9}a", 0) == 2 and utf8.size_at("a", 1) == 0)
    assert(utf8.utf16_len("a\u{1F600}b") == 4)
  }
}

t.group("hash"){
  t.test("checksums and digests"){
    assert(hash.crc32("") == 0)
    assert(hash.crc32("The quick brown fox jumps over the lazy dog") == 1095738169)
    assert(str.format("%x", hash.fnv1a("")) == "cbf29ce484222325")
    assert(str.format("%x", hash.sha256("abc")) ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }
}
