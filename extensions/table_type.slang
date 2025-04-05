// Extends table declaration to support
// 'TypeName{...} style syntax that is also used in the
// pattern matching

local p = require("slang/parser")

p.add_primitive_expression(
  "table_with_type",
  p.seq(
    p.token("'"),
    p.identifier(),
    p.table_literal() 
  ):map(func(list){
    local name = list[1]
    name = {type: "String", value: name.value}
    local table = list[2]
    append(table.fields, {type: "Field", key: +{"meta"}, value: +{{__type: -{name}}} })
    return table
  })
)

