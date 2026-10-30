// enum NAME { Member, Member, ... }: declares a local table whose members
// map to their own names, for use as symbolic values:
//
//   enum Color { Red, Green, Blue }
//   local c = Color.Red          // "Red"
//
// This extension also shows how an extension highlights its own syntax:
// the name is tagged `enum.declaration`, the members `enumMember.declaration`
// (any standard LSP token type and modifiers can be used in a category);
// the language server and `slang highlight` pass the tags through.
local peg = require("slang/peg")
local ast = require("slang/ast")
local g = require("slang/compiler").grammar()

local name = g:tag(g:rule("identifier"), "enum.declaration")
local member = g:tag(g:rule("identifier"), "enumMember.declaration")

g:statement(
  "enum",
  peg.seq(
    g:keyword("enum"), name, g:token("{"),
    member:star_separated(g:token(",")):map(func(s){ return s.elements }),
    g:token("}")
  )
    :map(func(r){
      local fields = {}
      for(let local m in values(r[3])){
        append(fields, ast.node(
          "Field",
          {
            key: ast.node("String", {value: m.value}, m),
            value: ast.node("String", {value: m.value}, m),
          }, m
        ))
      }
      local table = ast.node("Table", {fields: fields}, r[2])
      local id = ast.node("Identifier", {value: r[1].value}, r[1])
      return {
        token: r[0],
        ast: ast.node(
          "Declaration", {is_local: true, left: id, right: table}, r[0]
        ),
      }
    })
)
