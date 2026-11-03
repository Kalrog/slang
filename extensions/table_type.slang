// `'Name{...}`: a table literal with a type name, the same notation that
// patterns use to match one.
//
// `'Point{x: 1, y: 2}` is `{x: 1, y: 2, @meta: {__type: "Point"}}`: the
// table's metatable names its type, so type() returns "Point" and the
// pattern `'Point{...}` matches it (patterns understand `'Name{...}`
// without this extension). The name is an identifier; the braces hold an
// ordinary table literal.
//
//   local p = 'Point{x: 1, y: 2}
//   print(type(p), "\n")                         // Point
//   if(let 'Point{x: local x} = p){
//     print("a point at x = ", x, "\n")
//   }
//   if(let 'Line{} = p){
//     print("a line\n")
//   } else {
//     print("not a line\n")
//   }
//
// The metatable is a new table with `__type` only: an `@meta` field written
// in the literal is replaced, so a typed table cannot also carry methods
// this way. Set `p.@meta.__index` afterwards to give it some.
local peg = require("slang/peg")

local g = require("slang/compiler").grammar()

g
  :expression()
  :primary(
    "table_with_type",
    peg.seq(g:token("'"), g:rule("identifier"), g:rule("table_literal"))
      :map(func(list){
        local name = list[1]
        name = {type: "String", value: name.value}
        local table = list[2]
        append(table.fields, {type: "MetaField", value: +{{__type: -{name}}}})
        return table
      }),
  )
