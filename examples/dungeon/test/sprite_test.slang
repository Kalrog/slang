extension "dsl/sprite"
local t = require("slang/test")
local str = require("slang/string")

// a snippet compiled at run time is a unit of its own: it loads the DSL itself
local func snippet(source){
  return concat("extension \"dsl/sprite\"\n", source)
}

palette test_palette { r: "#ff0000", b: "#0000ff80" }

sprite dot test_palette {
  .r.
  rbr
  .r.
}

t.group("sprite DSL"){
  t.test("bakes rows into RGBA bytes at compile time"){
    local s = sprites.dot
    assert(s.w == 3 and s.h == 3, "size")
    assert(len(s.pixels) == 36, "36 bytes")
    assert(str.byte_at(s.pixels, 0) == 0 and str.byte_at(s.pixels, 3) == 0, "transparent first pixel")
    assert(str.byte_at(s.pixels, 4) == 255 and str.byte_at(s.pixels, 7) == 255, "red second pixel")
    local center = 4 * 4
    assert(str.byte_at(s.pixels, center + 2) == 255 and str.byte_at(s.pixels, center + 3) == 128, "blue with alpha in the middle")
  }
  t.test("ragged rows are a compile error on the offending line"){
    local r = pcall(compile, snippet("""palette pp { x: "#000000" }
sprite bad pp {
  xx
  x
}"""), "ragged")
    assert(r[0] == "err", "compile fails")
    assert(str.index_of(r[1].message, "row 2") >= 0, r[1].message)
    assert(r[1].location.line == 5, concat("line ", r[1].location.line))
    assert(r[1].location.origin == "ragged", "origin")
  }
  t.test("unknown characters are compile errors"){
    local r = pcall(compile, snippet("""palette pp { x: "#000000" }
sprite bad pp {
  xx
  xy
}"""), "unknown char")
    assert(r[0] == "err", "compile fails")
    assert(str.index_of(r[1].message, "\"y\" is not in the palette") >= 0, r[1].message)
    assert(r[1].location.line == 5, concat("line ", r[1].location.line))
  }
  t.test("unknown palettes and bad colors are compile errors"){
    local r = pcall(compile, snippet("sprite bad nope {\n x\n}"), "unknown palette")
    assert(r[0] == "err" and str.index_of(r[1].message, "unknown palette") >= 0, r[1].message)
    r = pcall(compile, snippet("palette pp { x: \"red\" }"), "bad color")
    assert(r[0] == "err" and str.index_of(r[1].message, "not a color") >= 0, r[1].message)
  }
  t.test("sprite statements are top-level only"){
    local r = pcall(compile, snippet("func f(){ sprite x test_palette {\n r\n} }"), "nested")
    assert(r[0] == "err", "compile fails")
  }
}
