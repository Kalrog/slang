// extensions/dollar: `macro` is a keyword, the macro's name is a function
// being declared (function.declaration), and `$` at a use is a macro token.
extension "extensions/dollar"

macro twice(args){
  local e = args[0]
  return +{-{e} + -{e}}
}

macro unless(args){
  local condition = args[0]
  local body = args[1]
  if(let 'Function{body: local real_body} = body){
    return +{stat: if(not -{condition})-{real_body}}
  }
  error("unless needs a block")
}

print("twice 21 = ", $twice(21), "\n")
$unless(1 > 2){
  print("the block runs because the condition is false\n")
}
