// `parser { rule -> ... }`: a PEG grammar written as a grammar, which
// evaluates to a slang/peg parser.
//
// Syntax:
//   expr ::= "parser" "{" rule+ "}"
//   rule ::= identifier "->" choice ";"?
//   choice ::= sequence ("|" sequence)*
//   sequence ::= item+
//   item ::= atom ("*" | "+" | "?" | "!" | "_" | fields)*
//   atom ::= string | identifier | "[" ⟨character class⟩ "]" | "$"
//          | "(" choice ")"
//   string ::= "\"" ⟨any characters but ", no escapes⟩ "\""
//   fields ::= "P" "(" (field ("," field)*)? ")"
//   field ::= identifier ":" [0-9]+
//
// The rules are separated by newlines (or `;`); the one named `start` is
// the parser the expression gives, the others are reachable from it by
// name, in any order, recursion included.
//
// In a rule, `"text"` matches the text and skips whitespace around it.
// `[a-z0-9_]` matches one character of a class, as [peg.pattern] does,
// and skips no whitespace. A rule's name matches that rule, `$` the end
// of the input. Parts written one after the other form a sequence, whose
// value is the list of their values; `|` is an ordered choice, the first
// alternative that matches wins.
//
// The suffixes: `*` zero or more and `+` one or more (a list), `?`
// optional (null when absent), `!` fails where the part matches and
// consumes nothing, `_` gives the matched text as one string, and
// `P(name: i, ...)` turns a sequence's list into a table whose field
// `name` is the list's element `i`.
//
// Each rule's value, when it is a table, gets the rule's name as its type
// (`meta.__type`), so `'name{...}` patterns can take results apart.
// Parse with [peg.parse], which gives `{"ok", value}` or `{"error",
// message}`.
//
//   local peg = require("slang/peg")
//   local assignment = parser {
//     start -> (name "=" number) P(name: 0, value: 2)
//     name -> ([a-z]+)_
//     number -> ([0-9]+)_
//   }
//   local r = peg.parse(assignment, "answer = 42")
//   if(let {"ok", 'start{name: local n, value: local v}} = r){
//     print(n, " is ", v, "\n")             // answer is 42
//   }
//   print(peg.parse(assignment, "42"), "\n") // the error: [a-z] expected
//
// The expression expands to a function call that declares one local
// function per rule (built from slang/peg's combinators) and returns the
// resolved `start` parser; the grammar is built each time the expression
// is evaluated, so keep the parser in a variable. Rule names must be
// identifiers that are not keywords; `P` followed by `(` is read as a
// fields suffix, not as a rule.
extension "extensions/lambda_shorthand"
extension "extensions/table_type"
extension "extensions/switch"

local peg = require("slang/peg")

local g = require("slang/compiler").grammar()

local func foldLeft(list, initial, f){
  local i = 0
  if(not f){
    f = initial
    initial = list[0]
    i = 1
  }
  local result = initial
  for(i = i; i < len(list); i = i + 1){
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

func parser_def(,
) => peg.seq(
  g:keyword("parser"),
  g:token("{"),
  peg.ref(rule_def):plus(),
  g:token("}"),
):pick(2):map(|rules| 'Parser{rules: rules})

func rule_def() => peg.seq(
  g:rule("identifier"),
  g:token("->"),
  peg.ref(rule),
  g:token(";"):optional(),
):map(|results| 'RuleDef{name: results[0], rule: results[2]})

func rule() => peg.ref(rule_or)

func rule_or() => peg.ref(rule_combine)
  :plus_seperated(g:token("|"))
  :map(|sep_list| 'RuleOr{
    rules: sep_list.elements,
  })

func rule_combine(,
) => peg.ref(rule_post_fix):plus():map(|list| 'RuleCombine{rules: list})

func rule_post_fix(,
) => peg.seq(peg.ref(rule_bracket), peg.choice(
  g:token("*"):map(|_| "*"),
  g:token("+"):map(|_| "+"),
  g:token("?"):map(|_| "?"),
  g:token("!"):map(|_| "!"),
  g:token("_"):map(|_| "_"),
  peg.ref(permute),
):star()):map(
  |results| foldLeft(results[1], results[0], |acc, elem| 'RulePostFix{value: acc, op: elem}),
)

func rule_bracket() => peg.choice(
  peg.seq(g:token("("), peg.ref(rule), g:token(")")):pick(1),
  peg.ref(rule_primitive),
)

func rule_primitive() => peg.choice(
  peg.ref(string),
  peg.ref(rule_ref),
  peg.ref(end_of_input),
  peg.ref(pattern),
)

func string(,
) => peg.seq(g:token("\""), peg.ref(string_content), g:token("\""))
  :pick(1)
  :map(|results| 'String{value: results})

func string_content() => peg.ref(string_char)
  :star_lazy(peg.char("\""))
  :map(|list| foldLeft(list, "", concat))

func string_char() => peg.any()

func rule_ref(,
) => g
  :rule("identifier")
  :seq(g:token("->"):forbid())
  :pick(0)
  :map(|results| 'RuleRef{name: results})

func pattern(,
) => peg.seq(g:token("["), peg.any():star_lazy(peg.char("]")):map(
  |list| foldLeft(list, "", |acc, elem| concat(acc, elem)),
), g:token("]")):pick(1):map(|results| 'Pattern{value: results})

func permute(,
) => peg.seq(
  g:token("P"),
  g:token("("),
  peg.ref(permute_field):star_seperated(g:token(",")),
  g:token(")"),
):pick(2):map(|numbers| 'Permute{fields: numbers.elements})

func permute_field(,
) => peg.seq(g:rule("identifier"), g:token(":"), peg.ref(number))
  :permute(0, 2)
  :map(|results| 'PermuteField{name: results[0], number: results[1]})

func number() => peg.pattern("0-9"):plus():flatten():map(to_int)

func end_of_input() => g:token("$"):map(|_| 'EndOfInput{})

func build_ast(ast){
  switch(ast){
    case 'Parser{rules: local rules}:
      local block = +{block:
        local peg = require("slang/peg")
        local g = require("slang/compiler").grammar()
      }
      for(let 'RuleDef{name: local name} in values(rules)){
        append(block.statements, +{stat: local -{name}})
      }
      for(let local rule in values(rules)){
        append(block.statements, build_ast(rule))
      }
      append(block.statements, +{stat: return peg.resolve(start())})
      return {
        type: "Call", function: {type: "Function", params: {}, body: block},
        args: {}
      }
    case 'RuleDef{name: local name, rule: local rule}:
      local function_def = +{stat:
        func name(){
          return -{build_ast(rule)}:map(func(result){
            if(_ENV.type(result) == "table"){
              result.meta = {__type: -{{type: "String", value: name.value}}}
            }
            return result
          })
        }
      }
      function_def.left = name
      return function_def
    case 'RuleOr{rules: local rules}:
      if(len(rules) == 1){
        return build_ast(rules[0])
      }
      local choice = +{peg.choice()}
      for(let local rule in values(rules)){
        append(choice.args, build_ast(rule))
      }
      return choice
    case 'RuleCombine{rules: local rules}:
      if(len(rules) == 1){
        return build_ast(rules[0])
      }
      local combine = +{peg.seq()}
      for(let local rule in values(rules)){
        append(combine.args, build_ast(rule))
      }
      return combine
    case 'RulePostFix{value: local value, op: "*"}:
      return +{-{build_ast(value)}:star()}
    case 'RulePostFix{value: local value, op: "+"}:
      return +{-{build_ast(value)}:plus()}
    case 'RulePostFix{value: local value, op: "?"}:
      return +{-{build_ast(value)}:optional()}
    case 'RulePostFix{value: local value, op: "!"}:
      return +{-{build_ast(value)}:forbid()}
    case 'RulePostFix{value: local value, op: "_"}:
      return +{-{build_ast(value)}:flatten()}
    case 'RulePostFix{value: local value, op: 'Permute{fields: local fields}}:
      local steps = +{block: }
      for(let local field in values(fields)){
        append(steps.statements, +{stat:
          out[-{
            {
              type: "String",
              value: field.name.value,
            }
          }] = result[-{{type: "Int", value: field.number}}]
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
      return +{peg.string(-{{type: "String", value: value}}):trim()}
    case 'RuleRef{name: local name}:
      return +{peg.ref(-{name})}
    case 'Pattern{value: local value}:
      return +{peg.pattern(-{{type: "String", value: value}})}
    case 'EndOfInput{}:
      return +{peg.end_of_input()}
    case local any:
      error("Unknown rule: ", any)
  }
}

g:expression():primary("parser_definition", peg.ref(parser_def):map(build_ast))
