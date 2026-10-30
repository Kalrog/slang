// The pipe operator |>, as in Elixir: the value on the left becomes the
// first argument of the call on the right.
//
//   x |> f(a, b)        is   f(x, a, b)
//   x |> obj:method(a)  is   obj:method(x, a)
//   x |> f              is   f(x)        (Elixir insists on f(); we allow both)
//
// It is left-associative, so pipelines read top to bottom, and it binds
// looser than arithmetic and tighter than comparison, so
// `n + 1 |> double() == 4` is `(double(n + 1)) == 4`.
local ast = require("slang/ast")
local fmt = require("slang/format")
local g = require("slang/compiler").grammar()

g:expression():level("pipe", {before: "compare", aliases: {"|>"}})
// for `slang fmt`: a pipeline is on one line or has a step per line,
// each starting with |>
:left(fmt.mark(g:token("|>", "|>", "operator"), {break_before: true, style: "lines"}), func(left, op, right){
  local call = null
  if(right.type == "Call"){
    call = ast.node(
      "Call", {function: right.function, args: {left, ...right.args}}, op
    )
  } else if(right.type == "Invoke"){
    call = ast.node(
      "Invoke",
      {receiver: right.receiver, name: right.name, args: {left, ...right.args}},
      op
    )
  } else {
    call = ast.node("Call", {function: right, args: {left}}, op)
  }
  return {token: op, ast: call}
})
