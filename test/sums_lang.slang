// a grammar dialect of test/project/slang.project: a .sums file is lines
// `name = number`, and its module is the table of them
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local str = require("slang/string")

local trivia = peg.custom(func(self, ctx, pos){
  local q = peg.space:match_at(ctx.buffer, pos)
  if(q == pos){
    return -1
  }
  ctx.value = null
  return q
})
trivia.trivia = true

local name = peg.seq(peg.pattern("a-z"), peg.pattern("a-z0-9_"):star())
  :flatten("expected a name")
  :token("property")
  :trim(trivia)
local number = peg.pattern("0-9")
  :plus()
  :flatten("expected a number")
  :token("number")
  :trim(trivia)
local equals = fmt.gaps(
  peg.string("="):token("operator"):trim(trivia), "space", "space"
)

return {
  item: fmt.mark(peg.seq(name, equals, number), {before: "hardline"}),
  unit: func(items, g){
    local fields = {}
    for(let local v in values(items)){
      append(fields, ast.node("Field", {
        key: ast.literal(v[0], v[0].value),
        value: ast.literal(v[2], str.parse_int(v[2].value, 10)),
      }, v[0]))
    }
    local table = ast.node("Table", {fields: fields}, null)
    return ast.node("Block", {
      statements: {ast.node("Return", {value: table}, null)},
    }, null)
  },
}
