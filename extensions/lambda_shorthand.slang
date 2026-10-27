  local peg = require("slang/peg")
  local g = require("slang/compiler").grammar()
  g:expression():primary(
    "lambda",
    peg.seq(
      g:token("|"),
      g:rule("param"):star_seperated(g:token(",")):map(func(values){
        return values.elements
      }),
      g:token("|"),
      g:rule("expr")
    ):map(func(results){
      local params = results[1]
      local expression = results[3]
      return {
        token:results[0],
        ast: {
          type: "Function", 
          params:params,
          body:+{block:return -{expression}}
        }
      }
    })
  );
