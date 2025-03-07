local test = {
  hello: "world",
  inner: {
    a: 1,
    b: 2,
  },
}
if(let {hello: local variable,inner:{b:2}} = test){
  print("match")
  assert(variable == "world")
}
if(let {hello: local variable,inner:{b:3}} = test){
  assert(false,"should never reach here")
}

local list = {1,2,3,4,5}

if(let {1, first, second,4} = list){
  print("match")
  assert(first == 2)
  assert(second == 3)
}

if(let {1,local var1, local var2,6} = list){
  assert(false,"should never reach here")
}

if(let {[2]:3,local var1} = list){
  print("match")
  assert(var1 == 4)
}

