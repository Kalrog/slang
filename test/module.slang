return func(mfunc){
  local m = {};
  m.meta = {__index:_ENV};
  mfunc(m);
  m.meta.__index = null;
  return m;
}


