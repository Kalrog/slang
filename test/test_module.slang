return module{
  global func add(a, b){
    return a + b
  }

  global func returnTrue(){
    return true
  }

  local privateVar = 10

  global publicVar = 20

  global func setPrivateVar(v){
    privateVar = v
  }

  global func getPrivateVar(){
    return privateVar
  }

  local func privateFunc(){
    return "private"
  }
}
