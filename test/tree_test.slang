local t = require("slang/test")
local peg = require("slang/peg")
local compiler = require("slang/compiler")
local os = require("slang/os")

// parses input with p for a tree; the tree must give input back and the
// value must be what a parse without a tree gives
local func round_trip(p, input){
  local r = peg.run(p, input, {tree: true})
  assert(r.ok, concat("parses: ", input))
  assert(peg.text(r.tree, input) == input, concat("text of the tree: ", peg.text(r.tree, input)))
  assert(peg.tree_gap(r.tree) == null, concat("no gaps: ", input))
  local plain = peg.run(p, input)
  assert(plain.value == r.value, concat("same value: ", input))
  return r
}

// the first node of tree (depth first) for which pred holds
local func find(tree, pred){
  if(tree == null){
    return null
  }
  if(pred(tree)){
    return tree
  }
  for(let local kid in values(tree.kids or {})){
    local found = find(kid, pred)
    if(found != null){
      return found
    }
  }
  return null
}

local func count(tree, pred){
  local n = 0
  if(pred(tree)){
    n = 1
  }
  for(let local kid in values(tree.kids or {})){
    n = n + count(kid, pred)
  }
  return n
}

t.group("lossless tree"){
  t.test("combinators keep every character"){
    local word = peg.pattern("a-z"):plus():flatten():trim()
    round_trip(peg.seq(word, peg.string(","), word):pick(2):end(), "  ab ,  cd  ")
    round_trip(word:star_separated(peg.string(",")):map(func(s){ return s.elements }):end(), "a, b ,c")
    round_trip(peg.seq(peg.string("x"):optional(), peg.string("y")):end(), "y")
    round_trip(peg.seq(peg.string("\""), peg.any():star_lazy(peg.string("\"")), peg.string("\"")):flatten():end(), "\"q w\"")
    round_trip(peg.seq(peg.string("a"):and(), peg.choice(peg.string("b"), peg.string("a")), peg.string("c"):forbid()):end(), "a")
    round_trip(peg.seq(peg.digit():plus(), peg.string(".")):permute(1, 0):token("num"):end(), "42.")
  }
  t.test("the tree records each parser and its span"){
    local item = peg.pattern("a-z"):plus():flatten()
    local list = peg.seq(peg.string("["), item:star_separated(peg.string(",")), peg.string("]"))
    local r = round_trip(list:end(), "[a,bc]")
    local sep = find(r.tree, func(n){ return n.p.kind == "separated" })
    assert(sep.start == 1 and sep.stop == 5, "span of the list")
    // elements and separators interleaved
    assert(len(sep.kids) == 3, concat("kids ", len(sep.kids)))
    assert(sep.kids[1].p.kind == "string", "the separator")
    local trim = find(round_trip(item:trim():end(), " ab ").tree, func(n){ return n.p.kind == "trim" })
    assert(trim.kids[trim.at].start == 1, "the trimmed child")
  }
  t.test("a custom parser is a leaf unless it builds its node"){
    local two = peg.custom(func(self, ctx, pos){
      ctx.value = "two"
      return pos + 2
    })
    local r = round_trip(peg.seq(two, peg.string("c")):end(), "abc")
    local node = find(r.tree, func(n){ return n.p == two })
    assert(node.kids == null and node.stop == 2, "a leaf")
    local built = peg.custom(func(self, ctx, pos){
      return pos + 1
    }, func(self, ctx, pos){
      ctx.tree = peg.node(self, pos, pos + 1, {peg.leaf(self, pos, pos + 1)})
      return pos + 1
    })
    local b = peg.run(built, "x", {tree: true})
    assert(len(b.tree.kids) == 1, "its own node")
  }
  t.test("memoized parsers cache their node"){
    local p = peg.memoize(peg.seq(peg.string("a"), peg.string("b")))
    round_trip(peg.choice(peg.seq(p, peg.string("x")), peg.seq(p, peg.string("y"))):end(), "aby")
  }
  t.test("expression walker"){
    local w = peg.walker()
    w:primary(peg.digit():plus():flatten():trim():map(to_int))
    w:level("bracket")
    w:wrapper(peg.char("("):trim(), peg.char(")"):trim(), "bracket", func(l, v, r){ return v })
    w:level("unary")
    w:prefix(peg.char("-"):trim(), "unary", func(op, v){ return -v })
    w:level("sum")
      :left(peg.char("+"):trim(), func(a, op, c){ return a + c })
    w:level("factorial")
    w:postfix(peg.char("!"):trim(), "factorial", func(v, op){
      local r = 1
      for(local i = 2; i <= v; i = i + 1){ r = r * i }
      return r
    })
    w:nud(peg.char("#"):trim(), 100, func(w, ctx, pos, op){
      local r = w:parse_at(ctx, pos, 100)
      if(r >= 0){
        ctx.value = ctx.value * 2
      }
      return r
    })
    local p = w:build():end()
    // factorial is the loosest level: ((1 + -2) + 3)! + #4
    local r = round_trip(p, " (1 + -2) + 3 ! + #4 ")
    assert(r.value == 10, concat("value ", r.value))
    for(let local form in values({"wrapper", "prefix", "left", "postfix"})){
      assert(find(r.tree, func(n){ return n.p.form == form }) != null, concat("a ", form, " node"))
    }
    local sum = find(r.tree, func(n){ return n.p.form == "left" })
    assert(sum.p.level == "sum" and len(sum.kids) == 3, "left operand, operator, right operand")
  }
}

t.group("lossless tree of slang"){
  t.test("comments, blank lines and extension syntax are kept"){
    local source = """// a file
extension {
  local g = require("slang/compiler").grammar()
  local peg = require("slang/peg")
  g:statement("shout", peg.seq(g:keyword("shout"), g:rule("expr")):map(func(r){
    return +{stat: local shouted = -{r[1]}}
  }))
}

local x = (1 + 2) * 3   // trailing

shout "hi"; shout   x
func f(a, b){ return a ^ b }
"""
    local tree = compiler.tree(source, "tree_test")
    assert(peg.text(tree, source) == source, "the source back")
    assert(peg.tree_gap(tree) == null, "no gaps")
    assert(tree.p.kind == "unit" and tree.start == 0 and tree.stop == len(source), "the unit")
    assert(len(tree.kids) == 5, concat("top-level statements: ", len(tree.kids)))
    local func rule(name){
      return func(n){ return n.p.kind == "rule" and n.p.rule_name == name }
    }
    assert(count(tree, rule("block")) == 3, "the extension block and the two function bodies")
    assert(find(tree, func(n){ return n.p.form == "wrapper" }) != null, "parentheses")
    local shout = find(tree, rule("expr"))
    assert(shout != null, "expressions inside the extension's syntax are rule nodes")
  }
  t.test("every file of the compiler and the libraries"){
    for(let local dir in values({"slang/compiler", "slang/lib", "extensions"})){
      for(let local name in values(os.list_dir(dir))){
        if(require("slang/string").ends_with(name, ".slang")){
          local path = concat(dir, "/", name)
          local source = os.read_file(path)
          local tree = compiler.tree(source, path)
          assert(peg.text(tree, source) == source, concat("round trip of ", path))
        }
      }
    }
  }
}
