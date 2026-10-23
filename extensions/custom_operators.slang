//special way to define operators
// each definition is an extension statement: it is parsed at the top level and
// its apply function registers the operator for the statements that follow
// "infix" "_"{symbol}"_" ("left","right")? (("after" {id})|("before" {id})|("at" {number}))? "(" {params}")" "{" {body} "}"
// creates an infix operator, that calls the function when the operator is used 
// "prefix" {symbol}_ (("after" {id})|("before" {id})|("at" {number}))? "(" {params}")" "{" {body} "}"
// creates a prefix operator, that calls the function when the operator is used
extension "extensions/lambda_shorthand"

local p = require("slang/parser")
p.add_extension_statement(
  "defineInfix",
  p.seq(
    p.keyword("infix"),
    p.token("_"),
    p.any():star_lazy(p.token("_")):flatten(),
    p.token("_"),
    p.choice(
      p.token("left"),
      p.token("right")
    ):optional(),
    p.choice(
      p.seq(
        p.token("after"):map(|_|"after"),
        p.seq(
          p.token("_"),
          p.any():star_lazy(p.string("_")):flatten(),
          p.token("_")
        ):pick(1)
      ),
      p.seq(
        p.token("before"):map(|_|"before"),
        p.seq(
          p.token("_"),
          p.any():star_lazy(p.string("_")):flatten(),
          p.token("_")
        ):pick(1)
      ),
      p.seq(
        p.token("at"):map(|_|"at"),
        p.digit():plus():flatten():map(to_int)
      )
    ):optional(),
    p.token("("),
    p.identifier():star_seperated(p.token(",")):map(|args| args.elements),
    p.token(")"),
    p.block()
  ),
  func(result){
    local symbol = p.token(result[2])
    local id = {type:"Identifier",value:concat("infix_", result[3])}
    local direction = result[4] 
    local position = result[5]
    local params = result[7]
    local body = result[9]
    local function_def = {
      type:"Declaration",
      is_local: false,
      left: id,
      right: {
        type:"Function",
        params:params,
        body:body
      }
    } 
    func define_infix(group){
      if(direction == "left"){
        group:left(symbol, func(left, op, right){
          return {
            token: op,
            ast: {type:"Call",function:id, args:{left, right}}
          }
        })
      } else{
        group:right(symbol, func(left, op, right){
          return {
            token: op,
            ast: {type:"Call",function:id, args:{left, right}}
          }
        })
      } 
      return group
    }

    if(position){
      if(position[0] == "after"){
        p.add_expression_group_after(position[1], id.value, define_infix) 
      } else if(position[0] == "before"){
        p.add_expression_group_before(position[1], id.value, define_infix) 
      } else if(position[0] == "at"){
        p.add_expression_group_at(position[1], id.value, define_infix) 
      } else {
        p.add_expression_group(id.value, define_infix) 
      }
    } else {
      p.add_expression_group(id.value, define_infix) 
    }
    return {
      token: result[0],
      ast: function_def
    }
  }
)

p.add_extension_statement(
  "definePrefix",
  p.seq(
    p.keyword("prefix"),
    p.any():star_lazy(p.token("_")):flatten():trim(),
    p.token("_"),
    p.choice(
      p.seq(
        p.token("after"):map(|_|"after"),
        p.seq(
          p.token("_"),
          p.any():star_lazy(p.string("_")):flatten(),
          p.token("_")
        ):pick(1)
      ),
      p.seq(
        p.token("before"):map(|_|"before"),
        p.seq(
          p.token("_"),
          p.any():star_lazy(p.string("_")):flatten(),
          p.token("_")
        ):pick(1)
      ),
      p.seq(
        p.token("at"):map(|_|"at"),
        p.digit():plus():flatten():map(to_int)
      )
    ):optional(),
    p.token("("),
    p.identifier():star_seperated(p.token(",")):map(|args| args.elements),
    p.token(")"),
    p.block()
  ),
  func(result){
    local symbol = p.token(result[1])
    local id = {type:"Identifier",value:concat("prefix_", result[1])}
    local position = result[3]
    local params = result[5]
    local body = result[7]
    local function_def = {
      type:"Declaration",
      is_local: false,
      left: id,
      right: {
        type:"Function",
        params:params,
        body:body
      }
    } 
    func define_prefix(group){
        group:prefix(symbol, func(op, right){
          return {
            token: op,
            ast: {type:"Call",function:id, args:{right}}
          }
        })
      return group
    }

    if(position){
      if(position[0] == "after"){
        p.add_expression_group_after(position[1], id.value, define_prefix) 
      } else if(position[0] == "before"){
        p.add_expression_group_before(position[1], id.value, define_prefix) 
      } else if(position[0] == "at"){
        p.add_expression_group_at(position[1], id.value, define_prefix) 
      } else {
        p.add_expression_group(id.value, define_prefix) 
      }
    } else {
      p.add_expression_group(id.value, define_prefix) 
    }
    return {
      token: result[0],
      ast: function_def
    }
  }
)

p.add_extension_statement(
  "definePostfix",
  p.seq(
    p.keyword("postfix"),
    p.token("_"),
    p.any():star_lazy(
      p.choice(
        p.token("("),
        p.token("after"),
        p.token("before"),
        p.token("at")
      )):flatten():trim(),
    p.choice(
      p.seq(
        p.token("after"):map(|_|"after"),
        p.seq(
          p.token("_"),
          p.any():star_lazy(p.string("_")):flatten(),
          p.token("_")
        ):pick(1)
      ),
      p.seq(
        p.token("before"):map(|_|"before"),
        p.seq(
          p.token("_"),
          p.any():star_lazy(p.string("_")):flatten(),
          p.token("_")
        ):pick(1)
      ),
      p.seq(
        p.token("at"):map(|_|"at"),
        p.digit():plus():flatten():map(to_int)
      )
    ):optional(),
    p.token("("),
    p.identifier():star_seperated(p.token(",")):map(|args| args.elements),
    p.token(")"),
    p.block()
  ),
  func(result){
    local symbol = p.token(result[2])
    local id = {type:"Identifier",value:concat("postfix_", result[2])}
    print("postfix id ", id, "\n")
    local position = result[3]
    local params = result[5]
    local body = result[7]
    local function_def = {
      type:"Declaration",
      is_local: false,
      left: id,
      right: {
        type:"Function",
        params:params,
        body:body
      }
    } 
    func define_postfix(group){
        group:postfix(symbol, func(left, op){
          return {
            token: op,
            ast: {type:"Call",function:id, args:{left}}  
          }
        })
      return group
    }

    if(position){
      if(position[0] == "after"){
        p.add_expression_group_after(position[1], id.value, define_postfix) 
      } else if(position[0] == "before"){
        p.add_expression_group_before(position[1], id.value, define_postfix) 
      } else if(position[0] == "at"){
        p.add_expression_group_at(position[1], id.value, define_postfix) 
      } else {
        p.add_expression_group(id.value, define_postfix) 
      }
    } else {
      p.add_expression_group(id.value, define_postfix) 
    }
    return {
      token: result[0],
      ast: function_def
    }
  }
)