// Control flow
//
// `if`, `else if` and `else` work as you would expect. There is one loop,
// `for`, in three forms: C style with init, condition and update; with a
// condition only; and `for(let ... in iterator)`, which comes on the next
// pages. `break` and `continue` work in all of them, and a label lets
// them reach an outer loop.
for(local i = 0; i < 5; i = i + 1){
  if(i == 1){
    continue
  } else if(i == 4){
    break
  }
  print("i = ", i, "\n")
}

local n = 3
for(n > 0){
  print("countdown ", n, "\n")
  n = n - 1
}

:rows: for(local r = 0; r < 3; r = r + 1){
  for(local c = 0; c < 3; c = c + 1){
    if(c > r){
      continue rows
    }
    print(r, ",", c, "  ")
  }
}
print("\n")
