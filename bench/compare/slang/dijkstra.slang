// shortest paths over a pseudo-random graph with a hand-written binary heap
local time = require("slang/time")
local n = 5000
local seed = 7
local func rand(m){
  seed = seed * 16807 % 2147483647
  return seed % m
}
local adj = {}
for(local i = 0; i < n; i = i + 1){
  append(adj, {})
}
for(local i = 0; i < n; i = i + 1){
  for(local k = 0; k < 4; k = k + 1){
    local j = rand(n)
    local w = rand(100) + 1
    append(adj[i], {j, w})
    append(adj[j], {i, w})
  }
}
local func shortest(src){
  local dist = {}
  for(local i = 0; i < n; i = i + 1){
    append(dist, 1000000000)
  }
  dist[src] = 0
  local hd = {0}
  local hn = {src}
  local size = 1
  for(size > 0){
    local d = hd[0]
    local u = hn[0]
    size = size - 1
    local ld = hd[size]
    local ln = hn[size]
    local i = 0
    for(true){
      local c = i * 2 + 1
      if(c >= size){
        break
      }
      if(c + 1 < size and hd[c + 1] < hd[c]){
        c = c + 1
      }
      if(hd[c] >= ld){
        break
      }
      hd[i] = hd[c]
      hn[i] = hn[c]
      i = c
    }
    hd[i] = ld
    hn[i] = ln
    if(d <= dist[u]){
      for(let local e in values(adj[u])){
        local v = e[0]
        local nd = d + e[1]
        if(nd < dist[v]){
          dist[v] = nd
          i = size
          size = size + 1
          if(i == len(hd)){
            append(hd, nd)
            append(hn, v)
          }
          for(i > 0){
            local p = to_int((i - 1) / 2)
            if(hd[p] <= nd){
              break
            }
            hd[i] = hd[p]
            hn[i] = hn[p]
            i = p
          }
          hd[i] = nd
          hn[i] = v
        }
      }
    }
  }
  local total = 0
  for(let local d in values(dist)){
    total = total + d
  }
  return total
}
local t0 = time.clock()
local check = 0
for(local s = 0; s < 20; s = s + 1){
  check = check + shortest(s)
}
print("dijkstra: ", check, " in ", time.clock() - t0, " ms\n")
