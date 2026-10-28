// slang/table: table helpers.
local m = {}

func m.contains(t, value){
  for (let local k in values(t)){
    if (k == value){
      return true
    }
  }
  return false
}

func m.map(t, f){
  local result = {}
  for (let local k in keys(t)){
    result[k] = f(t[k])
  }
  return result
}

func m.filter(t, f){
  local result = {}
  for (let local k in keys(t)){
    if (f(t[k])){
      result[k] = t[k]
    }
  }
  return result
}

func m.fold(t, init, f){
  local result = init
  for (let local k in keys(t)){
    result = f(result, t[k])
  }
  return result
}

func m.dequeue(t){
  return remove(t, 0)
}

func m.keys(t){
  local result = {}
  for (let local k in keys(t)){
    append(result, k)
  }
  return result
}

return m
