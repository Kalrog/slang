  local p = require("slang/parser")
  p.add_primitive_expression(
    "lambda",
    p.seq(
      p.token("|"),
      p.identifier():star_seperated(p.token(",")):map(func(values){
        return values.elements
      }),
      p.token("|"),
      p.expr()
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