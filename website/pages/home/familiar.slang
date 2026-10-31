local func counter(step){
  local n = 0
  return func(){
    n = n + step
    return n
  }
}

local tick = counter(5)
tick()
print(tick(), "\n") // 10

try {
  raise({kind: "not_found", path: "/notes"})
} catch({kind: "not_found", path: local p}) {
  print("missing ", p, "\n")
}
