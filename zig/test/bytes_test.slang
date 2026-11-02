// native extensions that take bytes take a buffer's as well as a string's
// (slang_checkbytes): zlib, crypto, sqlite blobs
local t = require("slang/test")
local buffer = require("slang/buffer")
local zlib = require("zlib")
local crypto = require("crypto")
local sqlite = require("sqlite")

local text = "a buffer's bytes, a buffer's bytes, a buffer's bytes"

t.group("bytes from buffers"){
  t.test("zlib and crypto read a buffer like the string of its bytes"){
    local b = buffer.from_string(text)
    assert(zlib.inflate(zlib.deflate(b)) == text)
    assert(crypto.hash("sha256", b) == crypto.hash("sha256", text))
    assert(crypto.hmac("sha256", b, b) == crypto.hmac("sha256", text, text))
    // any element type: its bytes
    local ints = buffer.from({1, 2}, "int32")
    assert(crypto.hash("sha1", ints) == crypto.hash("sha1", ints:to_string()))
    local r = pcall(zlib.deflate, {})
    assert(r[0] == "err")
    assert(
      r[1].message ==
        "bad argument #1 to 'deflate' (string or buffer expected, got table)",
    )
  }
  t.test("sqlite binds a buffer as a blob"){
    local db = sqlite.open(":memory:")
    db:exec("create table t (data blob)")
    db
      :prepare("insert into t values (?)")
      :bind(1, buffer.from({1, 2, 3}, "uint8"))
      :step()
    local q = db:prepare("select data, typeof(data) as kind from t")
    assert(q:step())
    local row = q:row()
    assert(row.kind == "blob" and len(row.data) == 3)
    assert(buffer.from_string(row.data):to_list() == {1, 2, 3})
    db:close()
  }
}

t.group("slang/zlib"){
  t.test("options tables; a stream's done is a property"){
    local z = require("slang/zlib")
    local packed = z.deflate("hello hello hello", {format: "zlib", level: 9})
    assert(z.inflate(packed) == "hello hello hello")
    assert(z.inflate(z.deflate("x", {format: "raw"}), {format: "raw"}) == "x")
    local c = z.compressor({format: "gzip"})
    local out = concat(c:push("part one, "), c:push("part two"))
    assert(not c.done)
    out = concat(out, c:finish())
    assert(c.done and type(c) == "zlib.Stream" and z.inflate(out) == "part one, part two")
    local d = z.decompressor()
    assert(concat(d:push(out), d:finish()) == "part one, part two")
    assert(z.c == zlib)
  }
}
