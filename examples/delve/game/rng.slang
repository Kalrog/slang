// A random number generator of the game's own, so that a seed gives the
// same dungeon whoever else draws random numbers (raylib, the autoplayer,
// a test): a 64-bit xorshift, seeded once per game.
local rng = {}

local state = 0x9E3779B97F4A7C15

func rng.seed(n){
  state = n ~ 0x9E3779B97F4A7C15
  if(state == 0){ state = 1 }
  // warm up, so that small seeds do not start alike
  for(local i = 0; i < 8; i = i + 1){ rng.next() }
}

// the next 63-bit non-negative integer
func rng.next(){
  local x = state
  x = x ~ (x << 13)
  x = x ~ (x >> 7)
  x = x ~ (x << 17)
  state = x
  return x & 0x7FFFFFFFFFFFFFFF
}

// an integer in lo..hi, both included
func rng.int(lo, hi){
  return lo + rng.next() % (hi - lo + 1)
}

// a float in 0..1
func rng.float(){
  return (rng.next() >> 11) / 4503599627370496.0
}

// true with probability p
func rng.chance(p){
  return rng.float() < p
}

// an element of a list
func rng.pick(list){
  return list[rng.int(0, len(list) - 1)]
}

// shuffles a list in place (Fisher-Yates) and returns it
func rng.shuffle(list){
  for(local i = len(list) - 1; i > 0; i = i - 1){
    local j = rng.int(0, i)
    local t = list[i]
    list[i] = list[j]
    list[j] = t
  }
  return list
}

return rng
