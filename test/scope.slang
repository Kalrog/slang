//testing correct scoping

func hello(){
  local x;
  x = 5;
}

hello();
assert(x==null);
