// extensions/async: async and await are keywords; everything else is the
// core language. Run it to see the awaited timer in action.
extension "extensions/async"
local a = require("slang/async")

local async func delayed(value, ms){
  await a.sleep(ms)
  return value
}

a.main(func(){
  local c = a.controller()
  a.run(func(){
    for(local i = 1; i <= 3; i = i + 1){
      c.add(await delayed(i * i, 10))
    }
    c.close()
  })
  await for(let local square in c.stream){
    print("square ", square, "\n")
  }
  print("sum ", (await delayed(20, 5)) + (await delayed(22, 5)), "\n")
})
