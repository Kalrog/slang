-{block:
  version="full"
  versionText = +{"Full version"}
  func in_demo(ast){
    if(version == "demo"){
      return ast;
    }else{
      return null;
    }
  }
  func in_full(ast){
    if(version == "demo"){
      return null;
    }else{
      return ast;
    }
  }
}

-{+{stat:print("Hello ", -{versionText}, "\n")}}

-{in_demo(+{stat:print("Demo version features.\n")})}
-{in_full(+{stat:print("Full version features.\n")})}