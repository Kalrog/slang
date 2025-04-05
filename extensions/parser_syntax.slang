-{block:
require("extensions/lambda_shorthand")
require("extensions/table_type")
require("extensions/switch")
}

local p = require("slang/parser")



//Grammar (ebnf inspired):
// parser_def -> "parser" "{" rule_def "}"
// rule_def -> id -> rule_exp* ";"
// rule_exp -> string | rule_combine | rule_ref | rule_or | rule_star | rule_plus | rule_opt | rule_bracket 
// string -> `string`
// rule_ref -> id
// rule_combine -> rule_exp rule_exp
// rule_or -> rule_exp "|" rule_exp 
// rule_star -> rule_exp "*"
// rule_plus -> rule_exp "+"
// rule_opt -> rule_exp "?"
// rule_bracket -> "(" rule_exp ")"

local func foldLeft(list,initial, f){
  local i = 0
  if(not f){
    f = initial
    initial = list[0]
    i = 1
  }
  local result = initial
  for (i=i;i < len(list); i = i + 1){
    result = f(result, list[i])
  }
  return result
}

local func foldRight(list, initial, f){
  local i = len(list) - 1
  if(not f){
    f = initial
    initial = list[i]
    i = i - 1
  }
  local result = initial
  for (i=i;i >= 0; i = i - 1){
    result = f(result, list[i])
  }
  return result
}

local parser_def
local rule_def
local rule
local rule_or
local rule_combine
local rule_post_fix
local rule_bracket
local rule_primitive
local string
local string_content
local string_char
local rule_ref
local pattern
local permute
local permute_field
local number
local end_of_input
local build_ast


func parser_def()=>
  p.seq( 
    p.keyword("parser"),
    p.token("{"),
    p.ref(rule_def):plus(),
    p.token("}")
  ):pick(2):map(|rules| 'Parser{rules:rules})

func rule_def()=>
  p.seq(
    p.identifier(),
    p.token("->"),
    p.ref(rule),
    p.token(";"):optional()
  ):map(|results| 'RuleDef{name:results[0], rule:results[2]})

func rule()=>
  p.ref(rule_or)

func rule_or()=>
  p.ref(rule_combine)
  :plus_seperated(p.token("|"))
  :map(|sep_list| 'RuleOr{rules:sep_list.elements})

func rule_combine()=>
  p.ref(rule_post_fix):plus() 
  :map(|list| 'RuleCombine{rules:list})

func rule_post_fix()=>
  p.seq(
    p.ref(rule_bracket),
    p.choice(
      p.token("*"):map(|_| "*"),
      p.token("+"):map(|_| "+"),
      p.token("?"):map(|_| "?"),
      p.token("!"):map(|_| "!"),
      p.token("_"):map(|_| "_"),
      p.ref(permute)
    ):star()
  ):map(|results| foldLeft(results[1], results[0], |acc, elem| 'RulePostFix{value:acc, op:elem}))

func rule_bracket()=>
  p.choice(
    p.seq(
      p.token("("),
      p.ref(rule),
      p.token(")")
    ):pick(1),
    p.ref(rule_primitive)
  )

func rule_primitive()=>
  p.choice(
    p.ref(string),
    p.ref(rule_ref),
    p.ref(end_of_input),
    p.ref(pattern)
  )

func string()=>
  p.seq(
    p.token("\""),
    p.ref(string_content),
    p.token("\"")
  ):pick(1):map(|results| 'String{value:results})

func string_content()=>
  p.ref(string_char):star_lazy(p.char("\"")):map(|list| foldLeft(list, "", concat))

func string_char()=>
  p.any()
 
func rule_ref()=>
  p.identifier():seq(p.token("->"):forbid()):pick(0):map(|results| 'RuleRef{name:results})

func pattern()=>
  p.seq(
    p.token("["),
    p.any():star_lazy(p.char("]")):map(|list| foldLeft(list, "", |acc, elem| concat(acc, elem))),
    p.token("]")
  ):pick(1):map(|results| 'Pattern{value:results})

func permute()=>
  p.seq(
    p.token("P"),
    p.token("("),
    p.ref(permute_field):star_seperated(p.token(",")),
    p.token(")")
  ):pick(2):map(|numbers| 'Permute{fields:numbers.elements})

func permute_field()=>
  p.seq(
    p.identifier(),
    p.token(":"),
    p.ref(number)
  ):permute(0,2):map(|results| 'PermuteField{name:results[0], number:results[1]})

func number()=>
  p.pattern("0-9"):plus():flatten():map(toInt)

func end_of_input()=>
  p.token("$"):map(|_| 'EndOfInput{})


func build_ast(ast){
  switch(ast){
    case 'Parser{rules: local rules}:
      local block = +{block:
        local p = require("slang/parser")
      }
      for(let 'RuleDef{name: local name} in values(rules)){
        append(block.statements, +{stat:
          local -{name}
        })
      } 
      for(let local rule in values(rules)){
        append(block.statements, build_ast(rule))
      }
      append(block.statements, +{stat:
        return p.resolve(start())
      })
      return {type:"Call", function:{type:"Function", params:{}, body:block}, args:{}}
    case 'RuleDef{name: local name, rule: local rule}:
      local function_def = +{stat: 
        func name(){ return -{build_ast(rule)}:map(func(result){
            if(_ENV.type(result) == "table"){
              result.meta = {__type:-{{type:"String", value:name.value}}}
            }
            return result
          })   
        } 
      }
      function_def.left = name
      return function_def
    case 'RuleOr{rules:local rules}:
      if(len(rules) == 1){
        return build_ast(rules[0])
      }
      local choice = +{
        p.choice() 
      }
      for(let local rule in values(rules)){
        append(choice.args, build_ast(rule))
      }
      return choice
    case 'RuleCombine{rules: local rules}:
      if(len(rules) == 1){
        return build_ast(rules[0])
      }
      local combine = +{
        p.seq()
      }
      for(let local rule in values(rules)){
        append(combine.args, build_ast(rule))
      }
      return combine
    case 'RulePostFix{value: local value, op: "*"}:
      return +{
        -{build_ast(value)}:star()
      }
    case 'RulePostFix{value: local value, op: "+"}:
      return +{
        -{build_ast(value)}:plus()
      }
    case 'RulePostFix{value: local value, op: "?"}:
      return +{
        -{build_ast(value)}:opt()
      }
    case 'RulePostFix{value: local value, op: "!"}:
      return +{
        -{build_ast(value)}:forbid()
      }
    case 'RulePostFix{value: local value, op: "_"}:
      return +{
        -{build_ast(value)}:flatten()
      }
    case 'RulePostFix{value: local value, op:'Permute{fields: local fields}}:
      local steps = +{block:}
      for (let local field in values(fields)){
        append(steps.statements, +{stat:
          out[-{{type:"String", value: field.name.value}}] = result[-{{type:"Int", value: field.number}}]
        })
      }
      local call = +{
        -{build_ast(value)}:map(func(result){
          local out = {}
          -{steps}
          return out
        })
      }
      return call
    case 'String{value: local value}:
      return +{
        p.string(-{{type:"String", value: value}}):trim()
      }
    case 'RuleRef{name: local name}:
      return +{
        p.ref(-{name})
      }
    case 'Pattern{value: local value}:
      return +{
        p.pattern(-{{type:"String", value: value}})
      }
    case 'EndOfInput{}:
      return +{
        p.end()
      }

    case local any:
      error("Unknown rule: ",any)
  }
}

p.add_primitive_expression(
  "parser_definition",
  p.ref(parser_def):map(build_ast)
)
