-- bench/compare/slang/dijkstra.slang in Lua (node and heap index i live at i + 1)
local floor = math.floor
local n = 5000
local seed = 7
local function rand(m)
  seed = seed * 16807 % 2147483647
  return seed % m
end
local adj = {}
for i = 1, n do
  adj[i] = {}
end
for i = 0, n - 1 do
  for _ = 1, 4 do
    local j = rand(n)
    local w = rand(100) + 1
    local a = adj[i + 1]
    a[#a + 1] = {j, w}
    local b = adj[j + 1]
    b[#b + 1] = {i, w}
  end
end
local function shortest(src)
  local dist = {}
  for i = 1, n do
    dist[i] = 1000000000
  end
  dist[src + 1] = 0
  local hd = {0}
  local hn = {src}
  local size = 1
  while size > 0 do
    local d = hd[1]
    local u = hn[1]
    size = size - 1
    local ld = hd[size + 1]
    local ln = hn[size + 1]
    local i = 0
    while true do
      local c = i * 2 + 1
      if c >= size then break end
      if c + 1 < size and hd[c + 2] < hd[c + 1] then c = c + 1 end
      if hd[c + 1] >= ld then break end
      hd[i + 1] = hd[c + 1]
      hn[i + 1] = hn[c + 1]
      i = c
    end
    hd[i + 1] = ld
    hn[i + 1] = ln
    if d <= dist[u + 1] then
      local edges = adj[u + 1]
      for k = 1, #edges do
        local e = edges[k]
        local v = e[1]
        local nd = d + e[2]
        if nd < dist[v + 1] then
          dist[v + 1] = nd
          i = size
          size = size + 1
          while i > 0 do
            local p = floor((i - 1) / 2)
            if hd[p + 1] <= nd then break end
            hd[i + 1] = hd[p + 1]
            hn[i + 1] = hn[p + 1]
            i = p
          end
          hd[i + 1] = nd
          hn[i + 1] = v
        end
      end
    end
  end
  local total = 0
  for i = 1, n do
    total = total + dist[i]
  end
  return total
end
local t0 = os.clock()
local check = 0
for s = 0, 19 do
  check = check + shortest(s)
end
print(string.format("dijkstra: %d in %.3f ms", check, (os.clock() - t0) * 1000))
