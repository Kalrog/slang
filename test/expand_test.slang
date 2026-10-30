// slang expand: the core AST printed back as slang
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local compiler = require("slang/compiler")
local vm = require("slang/vm")

// the stripped bytecode of a source
local func bytecode(source, origin){
  return vm.to_bytes(compile(source, origin), true)
}

// expanding a file and expanding the expansion give the same text, and the
// expansion compiles to the same bytecode as the original
local func round_trip(path){
  local source = os.read_file(path)
  local expanded = compiler.expand(source, path, {find_project: true})
  local again = compiler.expand(expanded, path, {find_project: true})
  assert(expanded == again, concat(path, ": printing is not idempotent"))
  assert(
    bytecode(source, path) == bytecode(expanded, path),
    concat(path, ": the expansion compiles differently")
  )
  return expanded
}

t.group("expand"){
  t.test("extensions disappear and their code shows"){
    local src = """
      extension "extensions/custom_operators"
      infix _<>_ (a, b){ return concat(a, b) }
      local v = "a" <> "b"
      extension "examples/functional/pipe"
      local w = v |> len()
    """
    local out = compiler.expand(src, "expanded.slang")
    assert(str.index_of(out, "extension") < 0, out)
    assert(str.index_of(out, "func infix_60_62(a, b)") >= 0, out)
    assert(str.index_of(out, "infix_60_62(\"a\", \"b\")") >= 0, out)
    assert(str.index_of(out, "len(v)") >= 0, out)
    assert(bytecode(src, "e") == bytecode(out, "e"), "same bytecode")
  }
  t.test("holes, defs and matchers print as core slang"){
    local src = """
      extension "examples/functional/holes"
      extension "examples/functional/def"
      local f = => _ + _2
      def area({w, h}){ return w * h }
      local ok = (let 'between(1, 2) as local x = 1)
    """
    local out = compiler.expand(src, "core.slang")
    assert(str.index_of(out, "local func f(__1, __2)") >= 0, out)
    assert(str.index_of(out, ".define(area, \"area\"") >= 0, out)
    assert(str.index_of(out, "'between(1, 2) as local x") >= 0, out)
    assert(bytecode(src, "c") == bytecode(out, "c"), "same bytecode")
  }
  t.test("precedence survives printing"){
    local src = "return {(1 + 2) * 3, 1 + 2 * 3, -(1 + 2), not (a and b), 2 ^ 3 ^ 2, (2 ^ 3) ^ 2, (a or b) and c, (f)(1), t[1 + 2], ...xs, -x ^ 2}"
    local out = compiler.expand(src, "prec.slang")
    assert(bytecode(src, "p") == bytecode(out, "p"), out)
  }
  t.test("the test suite and the examples round-trip"){
    local checked = 0
    for(let local name in values(os.list_dir("test"))){
      if(str.ends_with(name, "_test.slang")){
        round_trip(concat("test/", name))
        checked = checked + 1
      }
    }
    // the examples with a project file get it; the project (and its ambient
    // extensions) must not leak into the next file, so the compiler is reset
    for(let local path in values({
      "examples/webserver/main.slang",
      "examples/webserver/views.slang",
      "examples/breakout/main.slang",
      "slang/compiler/grammar.slang",
      "slang/lib/async.slang",
      "examples/functional/main.slang",
    })){
      round_trip(path)
      compiler.reset()
      checked = checked + 1
    }
    assert(checked > 30)
  }
}
