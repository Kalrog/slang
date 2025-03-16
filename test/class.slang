local vm = require("slang/vm")
return func (classOrSuper,classOrNull){
  local super;
  local classdef;
  if(classOrNull){
    super = classOrSuper;
    classdef = classOrNull;
  }else{
    super = null;
    classdef = classOrSuper;
  }
  local m = {
    super: super,
  }
  m.meta = {__index:_ENV};
  vm.setUpvalue(mfunc,"_ENV", m);
  classdef();
  m.meta.__index = null;
  return m;
}
