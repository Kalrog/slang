// Extends table declaration to support
// 'TypeName{...} style syntax that is also used in the
// pattern matching

local peg = require("slang/peg")

local g = require("slang/compiler").grammar()

g:expression():primary(
  "table_with_type",
  peg.seq(
    g:token("'"),
    g:rule("identifier"),
    g:rule("table_literal") 
  ):map(func(list){
    local name = list[1]
    name = {type: "String", value: name.value}
    local table = list[2]
    append(table.fields, {type: "Field", key: +{"meta"}, value: +{{__type: -{name}}} })
    return table
  })
)

