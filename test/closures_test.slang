func counter(n){
  local v = 0
  return {
    inc: func(){
      v = v + n
      return v
    },
    dec: func(){
      v = v - n
      return v
    },
  }
}
local tbl = counter(2)
local inc = tbl.inc
local dec = tbl.dec
assert(inc() == 2)
assert(inc() == 4)
assert(dec() == 2)
assert(dec() == 0)
assert(dec() == -2)
assert(inc() == 0)
