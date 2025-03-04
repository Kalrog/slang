local test = {
  hello: "world",
  inner: {
    a: 1,
    b: 2,
  },
}

if({hello: local variable,inner:{b:2}} = test){
  print("match")
  print(variable)
}