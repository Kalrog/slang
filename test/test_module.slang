return module{

  func add(a,b){
    return a+b;
  }

  func returnTrue(){
    return true;
  }

  local privateVar = 10;

  publicVar = 20;

  func setPrivateVar(v){
    privateVar = v;
  }

  func getPrivateVar(){
    return privateVar;
  }

  local func privateFunc(){
    return "private";
  }
}
