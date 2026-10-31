local t = require("slang/test")
local peg = require("slang/peg")
local compiler = require("slang/compiler")
local os = require("slang/os")
local str = require("slang/string")

// parses input with p for a tree; the tree must give input back and the
// value must be what a parse without a tree gives
local func round_trip(p, input){
  local r = peg.run(p, input, {tree: true})
  assert(r.ok, concat("parses: ", input))
  assert(
    peg.text(r.tree, input) == input,
    concat("text of the tree: ", peg.text(r.tree, input)),
  )
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
    round_trip(
      peg.seq(word, peg.string(","), word):pick(2):end(),
      "  ab ,  cd  ",
    )
    round_trip(
      word
        :star_separated(peg.string(","))
        :map(func(s){ return s.elements })
        :end(),
      "a, b ,c",
    )
    round_trip(peg.seq(peg.string("x"):optional(), peg.string("y")):end(), "y")
    round_trip(
      peg.seq(
        peg.string("\""), peg.any():star_lazy(peg.string("\"")),
        peg.string("\"")
      )
        :flatten()
        :end(),
      "\"q w\"",
    )
    round_trip(peg.seq(
      peg.string("a"):and(),
      peg.choice(peg.string("b"), peg.string("a")),
      peg.string("c"):forbid(),
    ):end(), "a")
    round_trip(
      peg.seq(peg.digit():plus(), peg.string("."))
        :permute(1, 0)
        :token("num")
        :end(),
      "42.",
    )
  }
  t.test("the tree records each parser and its span"){
    local item = peg.pattern("a-z"):plus():flatten()
    local list = peg.seq(
      peg.string("["), item:star_separated(peg.string(",")), peg.string("]")
    )
    local r = round_trip(list:end(), "[a,bc]")
    local sep = find(r.tree, func(n){ return n.p.kind == "separated" })
    assert(sep.start == 1 and sep.stop == 5, "span of the list")
    // elements and separators interleaved
    assert(len(sep.kids) == 3, concat("kids ", len(sep.kids)))
    assert(sep.kids[1].p.kind == "string", "the separator")
    local trim = find(round_trip(item:trim():end(), " ab ").tree, func(n){
      return n.p.kind == "trim"
    })
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
    local built = peg.custom(
      func(self, ctx, pos){
        return pos + 1
      },
      func(self, ctx, pos){
        ctx.tree = peg.node(self, pos, pos + 1, {peg.leaf(self, pos, pos + 1)})
        return pos + 1
      },
    )
    local b = peg.run(built, "x", {tree: true})
    assert(len(b.tree.kids) == 1, "its own node")
  }
  t.test("memoized parsers cache their node"){
    local p = peg.memoize(peg.seq(peg.string("a"), peg.string("b")))
    round_trip(
      peg.choice(peg.seq(p, peg.string("x")), peg.seq(p, peg.string("y"))):end(,
      ),
      "aby",
    )
  }
  t.test("expression walker"){
    local w = peg.walker()
    w:primary(peg.digit():plus():flatten():trim():map(to_int))
    w:level("bracket")
    w:wrapper(
      peg.char("("):trim(), peg.char(")"):trim(), "bracket", func(l, v, r){
        return v
      }
    )
    w:level("unary")
    w:prefix(peg.char("-"):trim(), "unary", func(op, v){ return -v })
    w:level("sum"):left(peg.char("+"):trim(), func(a, op, c){ return a + c })
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
      assert(
        find(r.tree, func(n){ return n.p.form == form }) != null,
        concat("a ", form, " node"),
      )
    }
    local sum = find(r.tree, func(n){ return n.p.form == "left" })
    assert(
      sum.p.level == "sum" and len(sum.kids) == 3,
      "left operand, operator, right operand",
    )
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
    assert(
      tree.p.kind == "unit" and tree.start == 0 and tree.stop == len(source),
      "the unit",
    )
    assert(
      len(tree.kids) == 5,
      concat("top-level statements: ", len(tree.kids)),
    )
    local func rule(name){
      return func(n){ return n.p.kind == "rule" and n.p.rule_name == name }
    }
    assert(
      count(tree, rule("block")) == 3,
      "the extension block and the two function bodies",
    )
    assert(
      find(tree, func(n){ return n.p.form == "wrapper" }) != null,
      "parentheses",
    )
    local shout = find(tree, rule("expr"))
    assert(
      shout != null,
      "expressions inside the extension's syntax are rule nodes",
    )
  }
  // (the whole repository is checked by hand when the parser changes; these
  // stay small enough for the debug and GC stress builds)
  t.test("files of the libraries and extensions"){
    for(let local path in values({
      "slang/lib/json.slang",
      "extensions/switch.slang",
      "extensions/enum.slang",
    })){
      local source = os.read_file(path)
      local tree = compiler.tree(source, path)
      assert(peg.text(tree, source) == source, concat("round trip of ", path))
    }
  }
}

t.group("layers"){
  local word = peg.pattern("a-z"):plus():flatten():trim()
  local item = peg.seq(word, peg.seq(peg.string("="), word):pick(1):optional())
    :map(func(v){
      return {name: v[0], value: v[1]}
    })
  local list = peg.seq(
    peg.string("["):trim(),
    item:star_separated(peg.string(",")),
    peg.string("]"),
  ):pick(1):map(func(s){
    return s.elements
  }):end()

  t.test("text keeps every character, raw drops whitespace and transforms"){
    local input = "[ a = b, c ]"
    local r = peg.run(list, input, {tree: true})
    local text = peg.evaluate(r.tree, "text", input)
    // nested lists of strings: the trimmed "[" with its trivia, then the items
    assert(text[0][0] == {"[", " "}, concat("text ", string(text[0][0])))
    local raw = peg.evaluate(r.tree, "raw", input)
    // no whitespace, the separated list interleaved, an absent value null
    local items = raw[0][1]
    assert(
      items[0] == {"a", {"=", "b"}},
      concat("raw first item ", string(items[0])),
    )
    assert(items[1] == ",", "the separator")
    assert(items[2][0] == "c" and items[2][1] == null, "the absent value")
  }
  t.test("the default layer is the parse's value, and replays to it"){
    local input = "[a=b,c]"
    local r = peg.run(list, input, {tree: true})
    assert(peg.evaluate(r.tree, "default", input) == r.value, "stored")
    assert(
      peg.evaluate(r.tree, "default", input, {replay: true}) == r.value,
      "replayed",
    )
  }
  t.test("a custom layer transforms where its operations are"){
    local names = peg.layer("names", "raw")
    // in the names layer an item is its name, the list the names
    local named_item = item:on(names, func(v){ return v:pick(0) })
    local names_list = peg.seq(
      peg.string("["):trim(),
      named_item:star_separated(peg.string(",")),
      peg.string("]"),
    ):on(names, func(v){
      return v:pick(1):map(func(items){
        local out = {}
        for(local i = 0; i < len(items); i = i + 2){ append(out, items[i]) }
        return out
      })
    }):end()
    local input = "[a=b, c, d=e]"
    local r = peg.run(names_list, input, {tree: true})
    assert(
      peg.evaluate(r.tree, names, input)[0] == {"a", "c", "d"},
      "the names",
    )
    // the default layer is not touched
    assert(r.value == peg.run(peg.seq(
        peg.string("["):trim(),
        item:star_separated(peg.string(",")),
        peg.string("]"),
      ):end(), input).value, "default unchanged")
  }
  t.test("a layer on default changes only the subtrees it has operations in"){
    local upper = peg.layer("upper", "default")
    local shout = word:on(upper, func(v){
      return v:map(func(s){ return require("slang/string").upper(s) })
    })
    local p = peg.seq(shout, peg.string(":"), word)
      :map(func(v){ return concat(v[0], "/", v[2]) })
      :end()
    local input = "ab:cd"
    local r = peg.run(p, input, {tree: true})
    assert(r.value == "ab/cd", "default")
    assert(
      peg.evaluate(r.tree, upper, input) == "AB/cd",
      concat("upper ", peg.evaluate(r.tree, upper, input)),
    )
  }
  t.test("marks annotate nodes; a shared parser keeps no operations"){
    local fmt = peg.layer("fmt", "text")
    local r_ref = peg.ref(func(){ return word })
    local marked = r_ref:mark(fmt, {space: "after"})
    local p = peg.seq(marked, r_ref):end()
    local input = "a b"
    local r = peg.run(p, input, {tree: true})
    local first = find(r.tree, func(n){ return n.p == marked })
    assert(peg.marks(first, fmt) == {{space: "after"}}, "the mark")
    assert(
      count(r.tree, func(n){ return len(peg.marks(n, fmt)) > 0 }) == 1,
      "the other use is not marked",
    )
    assert(r_ref.layer_ops == null, "the shared parser is unchanged")
    // marks leave values alone
    assert(
      peg.evaluate(r.tree, fmt, input) == peg.evaluate(r.tree, "text", input),
      "same value",
    )
  }
  t.test("walker nodes replay their callbacks"){
    local w = peg.walker()
    w:primary(peg.digit():plus():flatten():trim():map(to_int))
    w:level("bracket")
    w:wrapper(
      peg.char("("):trim(), peg.char(")"):trim(), "bracket", func(l, v, r){
        return v
      }
    )
    w:level("unary")
    w:prefix(peg.char("-"):trim(), "unary", func(op, v){ return -v })
    w:level("sum"):left(peg.char("+"):trim(), func(a, op, c){ return a + c })
    local p = w:build():end()
    local input = "(1 + -2) + 3"
    local r = peg.run(p, input, {tree: true})
    assert(
      peg.evaluate(r.tree, "default", input, {replay: true}) == 2,
      "replayed",
    )
    local raw = peg.evaluate(r.tree, "raw", input)
    assert(raw[0][1] == "+", concat("raw: the operator ", string(raw[0])))
  }
  t.test("the default layer of a slang file replays to its AST"){
    local ast = require("slang/ast")
    local source = """local x = {a: 1, [2]: "b"}
func f(n){ return n * 2 + x.a }
for(local i = 0; i < 3; i = i + 1){ f(i) }
"""
    local tree = compiler.tree(source, "layers_test")
    local stored = peg.evaluate(tree, "default", source)
    local replayed = peg.evaluate(tree, "default", source, {replay: true})
    assert(len(stored) == 3 and len(replayed) == 3, "three statements")
    for(local i = 0; i < 3; i = i + 1){
      assert(
        ast.to_source(stored[i]) == ast.to_source(replayed[i]),
        concat("statement ", i),
      )
    }
  }
}

t.group("highlights"){
  local word = peg.pattern("a-z"):plus():flatten()
  local keyword = peg.token(word, func(w){
    if(w == "if" or w == "else"){
      return "keyword"
    }
    return null
  })
  local number = peg.token(peg.digit():plus():flatten(), "number")
  local item = peg.choice(
    number,
    peg.tag(keyword, "word"):trim(peg.whitespace()),
  )

  t.test("tokens, tags and category functions"){
    local input = "if 12 x else"
    local p = peg.choice(number, keyword):trim(peg.whitespace()):star():end()
    local r = peg.run(p, input, {tree: true})
    local spans = {}
    for(let local s in values(peg.highlights(r.tree, input))){
      append(spans, concat(
        s.category, ":", str.substring(input, s.start, s.stop)
      ))
    }
    // x has no category
    assert(
      spans == {"keyword:if", "number:12", "keyword:else"},
      str.join(spans, " "),
    )
  }
  t.test("a tag wins over the tokens inside it"){
    local input = "if 3"
    local r = peg.run(item:star():end(), input, {tree: true})
    local spans = {}
    for(let local s in values(peg.highlights(r.tree, input))){
      append(spans, concat(
        s.category, ":", str.substring(input, s.start, s.stop)
      ))
    }
    assert(spans == {"word:if", "number:3"}, str.join(spans, " "))
  }
  t.test("a custom parser's tree holds the rules it parsed through peg.sub"){
    local input = "a # note\nb"
    local names = peg.token(peg.pattern("ab"), "name")
    local rest = peg.seq(
      peg.string(" "), peg.pattern("#a-z "):plus(), peg.string("\n")
    ):flatten()
    local custom = peg.custom(func(self, ctx, pos){
      local q = peg.sub(names, ctx, pos)
      if(q < 0){
        return - 1
      }
      q = rest:parse_on(ctx, q)
      return peg.sub(names, ctx, q)
    })
    local r = peg.run(custom:end(), input, {tree: true})
    assert(r.ok, "parses")
    assert(peg.text(r.tree, input) == input, "lossless")
    local spans = {}
    for(let local s in values(peg.highlights(r.tree, input))){
      append(spans, concat(
        s.category, ":", str.substring(input, s.start, s.stop)
      ))
    }
    assert(spans == {"name:a", "name:b"}, str.join(spans, " "))
  }
}
