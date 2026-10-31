extension {
  local g = require("slang/compiler").grammar()
  local pipe = g:expression():level("pipe", {after: "or"})
  pipe:left(g:token("|>"), func(left, op, right){
    return +{expr: -{right}(-{left})}
  })
}

local double = func(x) => x * 2
print(5 |> double |> double, "\n") // 20
