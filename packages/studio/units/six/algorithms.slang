// The 32 algorithms of the classic six-operator FM synthesizers: which
// operator modulates which, which ones are heard (the carriers), and where
// the feedback loop is. Operators are numbered 1 to 6 as on the panel; a
// modulator always has a higher number than what it modulates, so computing
// 6 down to 1 has every input ready. A feedback loop feeds an operator's
// last two outputs back into one (itself, or in 4 and 6 an operator above
// it, which then hears the previous sample).
//
// Each algorithm is written as edges "6>5" (6 modulates 5) and its feedback
// "fb6" (6 into itself) or "fb4>6" (4's output into 6).
local str = require("slang/string")

local algorithms = {}

local specs = {
  "2>1 4>3 5>4 6>5 fb6",
  "2>1 4>3 5>4 6>5 fb2",
  "2>1 3>2 5>4 6>5 fb6",
  "2>1 3>2 5>4 6>5 fb4>6",
  "2>1 4>3 6>5 fb6",
  "2>1 4>3 6>5 fb5>6",
  "2>1 4>3 5>3 6>5 fb6",
  "2>1 4>3 5>3 6>5 fb4",
  "2>1 4>3 5>3 6>5 fb2",
  "2>1 3>2 5>4 6>4 fb3",
  "2>1 3>2 5>4 6>4 fb6",
  "2>1 4>3 5>3 6>3 fb2",
  "2>1 4>3 5>3 6>3 fb6",
  "2>1 4>3 5>4 6>4 fb6",
  "2>1 4>3 5>4 6>4 fb2",
  "2>1 3>1 5>1 4>3 6>5 fb6",
  "2>1 3>1 5>1 4>3 6>5 fb2",
  "2>1 3>1 4>1 5>4 6>5 fb3",
  "2>1 3>2 6>4 6>5 fb6",
  "3>1 3>2 5>4 6>4 fb3",
  "3>1 3>2 6>4 6>5 fb3",
  "2>1 6>3 6>4 6>5 fb6",
  "3>2 6>4 6>5 fb6",
  "6>3 6>4 6>5 fb6",
  "6>4 6>5 fb6",
  "3>2 5>4 6>4 fb6",
  "3>2 5>4 6>4 fb3",
  "2>1 4>3 5>4 fb5",
  "4>3 6>5 fb6",
  "4>3 5>4 fb5",
  "6>5 fb6",
  "fb6",
}

// parse(spec) -> {mods: {[op]: {op}}, carriers: {op}, fb_from, fb_to}
local func parse(spec){
  local a = {mods: {}, carriers: {}, targets: {}}
  for(local k = 1; k <= 6; k = k + 1){
    a.mods[k] = {}
    a.targets[k] = {}
  }
  for(let local part in values(str.fields(spec))){
    if(str.starts_with(part, "fb")){
      local rest = str.substring(part, 2)
      local pair = str.cut(rest, ">")
      if(pair == null){
        a.fb_from = to_int(rest)
        a.fb_to = a.fb_from
      } else {
        a.fb_from = to_int(pair[0])
        a.fb_to = to_int(pair[1])
      }
    } else {
      local pair = str.cut(part, ">")
      local from = to_int(pair[0])
      local to = to_int(pair[1])
      append(a.mods[to], from)
      append(a.targets[from], to)
    }
  }
  for(local k = 1; k <= 6; k = k + 1){
    if(len(a.targets[k]) == 0){
      append(a.carriers, k)
    }
  }
  return a
}

algorithms.list = {}
for(let local s in values(specs)){
  append(algorithms.list, parse(s))
}
algorithms.count = len(algorithms.list)

// get(n) -> the algorithm numbered n (1..32)
func algorithms.get(n){
  return algorithms.list[n - 1]
}

// is_carrier(alg, op) -> bool
func algorithms.is_carrier(a, op){
  return len(a.targets[op]) == 0
}

// layout(alg) -> {[op]: {col, row}}: where to draw each operator, carriers
// on row 0 and every modulator one row above the highest it modulates;
// columns run left to right through the carriers' stacks
func algorithms.layout(a){
  local row = {}
  // rows, from the top operator down (6 first: its targets are below)
  for(local k = 1; k <= 6; k = k + 1){
    row[k] = 0
  }
  for(local k = 1; k <= 6; k = k + 1){
    for(let local m in values(a.mods[k])){
      // a modulator sits above its target; targets are numbered lower, so
      // going up from 1 settles every row before it is used
      if(row[k] + 1 > row[m]){
        row[m] = row[k] + 1
      }
    }
  }
  // repeat until stable (a modulator of a modulator moves up again)
  for(local pass = 0; pass < 6; pass = pass + 1){
    for(local k = 1; k <= 6; k = k + 1){
      for(let local m in values(a.mods[k])){
        if(row[k] + 1 > row[m]){
          row[m] = row[k] + 1
        }
      }
    }
  }
  // columns: a depth-first walk from each carrier, modulators placed in
  // order above; an operator shared by several (6>4 6>5) is placed once
  local col = {}
  local next_col = 0
  local func place(k){
    if(col[k] != null){
      return null
    }
    local mods = a.mods[k]
    if(len(mods) == 0){
      col[k] = next_col
      next_col = next_col + 1
      return null
    }
    local first = null
    for(let local m in values(mods)){
      place(m)
      if(first == null){
        first = col[m]
      }
    }
    // under its first modulator, or one to the right of the last when that
    // one stands above another carrier already
    col[k] = first
    if(col[k] == null){
      col[k] = next_col
      next_col = next_col + 1
    }
  }
  for(let local c in values(a.carriers)){
    place(c)
  }
  // two operators may land on one cell (a shared modulator's targets):
  // spread them
  local taken = {}
  for(local k = 1; k <= 6; k = k + 1){
    local key = concat(string(col[k]), ",", string(row[k]))
    for(taken[key] != null){
      col[k] = col[k] + 1
      if(col[k] >= next_col){
        next_col = col[k] + 1
      }
      key = concat(string(col[k]), ",", string(row[k]))
    }
    taken[key] = true
  }
  local out = {}
  for(local k = 1; k <= 6; k = k + 1){
    out[k] = {col: col[k], row: row[k]}
  }
  out.cols = next_col
  return out
}

return algorithms
