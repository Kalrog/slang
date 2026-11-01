// Dijkstra's algorithm
local queue = {}
local func queue_insert(node, weight){
  append(queue, {node, weight})
}
local func queue_pop(){
  local min = 0
  for(local i = 1; i < len(queue); i = i + 1) {
    if(queue[i][1] < queue[min][1]){
      min = i
    }
  }
  local node = queue[min][0]
  remove(queue, min)
  return node
}
local graph = {}

func new_graph(){
  local self = {nodes: {}, edges: {}}
  self.meta = {__index: graph}
  return self
}

func graph.add_edge(graph, node1, node2, weight){
  local connection = {node1, node2, weight}
  graph.nodes[node1] = graph.nodes[node1] or {}
  graph.nodes[node2] = graph.nodes[node2] or {}
  append(graph.nodes[node1], connection)
  append(graph.nodes[node2], connection)
  append(graph.edges, connection)
}

func graph.dijkstra(graph, start){
  local dist = {}
  local prev = {}
  for(let local node in keys(graph.nodes)){
    dist[node] = 100000000
    prev[node] = null
  }
  dist[start] = 0
  queue_insert(start, 0)
  for(len(queue) > 0){
    local node = queue_pop()
    for(let local connection in values(graph.nodes[node])){
      local alt = dist[node] + connection[2]
      local other
      if(connection[1] == node){
        other = connection[0]
      } else {
        other = connection[1]
      }
      if(alt < dist[other]){
        dist[other] = alt
        prev[other] = node
        queue_insert(other, alt)
      }
    }
  }
  return {distance: dist, previous: prev}
}

local g = new_graph()

g:add_edge("fix", "screw", 52)
g:add_edge("so", "flawed", 50)
g:add_edge("edition", "reliable", 95)
g:add_edge("heavy", "freedom", 35)
g:add_edge("house", "charge", 35)
g:add_edge("exclusive", "habitat", 52)
g:add_edge("solve", "reliable", 83)
g:add_edge("read", "charge", 21)
g:add_edge("remark", "orchestra", 53)
g:add_edge("leaflet", "edition", 64)
g:add_edge("courage", "compose", 37)
g:add_edge("read", "promise", 5)
g:add_edge("pound", "exclusive", 66)
g:add_edge("engine", "contact", 81)
g:add_edge("edition", "pound", 5)
g:add_edge("danger", "leaflet", 85)
g:add_edge("contact", "technique", 84)
g:add_edge("worth", "technique", 7)
g:add_edge("humor", "basketball", 52)
g:add_edge("courage", "freedom", 97)
g:add_edge("left", "pound", 75)
g:add_edge("workshop", "solve", 53)
g:add_edge("freedom", "promise", 1)
g:add_edge("medicine", "quality", 89)
g:add_edge("symptom", "heavy", 42)
g:add_edge("fuel", "intervention", 61)
g:add_edge("intervention", "basketball", 33)
g:add_edge("contact", "intervention", 7)
g:add_edge("remark", "symptom", 81)
g:add_edge("regret", "quality", 30)
g:add_edge("heavy", "humor", 99)
g:add_edge("broken", "technique", 76)
g:add_edge("worth", "top", 62)
g:add_edge("worth", "habitat", 56)
g:add_edge("freedom", "quality", 17)
g:add_edge("beach", "censorship", 17)
g:add_edge("chimpanzee", "solve", 66)
g:add_edge("negotiation", "wash", 76)
g:add_edge("orchestra", "quality", 65)
g:add_edge("screw", "heavy", 8)
g:add_edge("edition", "flawed", 42)
g:add_edge("left", "screw", 44)
g:add_edge("pressure", "promise", 89)
g:add_edge("exclusive", "regret", 16)
g:add_edge("basketball", "chimpanzee", 19)
g:add_edge("regulation", "screw", 72)
g:add_edge("censorship", "fix", 79)
g:add_edge("broken", "danger", 27)
g:add_edge("charge", "edition", 80)
g:add_edge("solve", "fix", 86)
g:add_edge("danger", "basketball", 15)
g:add_edge("courage", "heavy", 81)
g:add_edge("left", "orchestra", 47)
g:add_edge("remark", "edition", 7)
g:add_edge("flawed", "edition", 0)
g:add_edge("leaflet", "hurt", 15)
g:add_edge("technique", "heavy", 32)
g:add_edge("hurt", "left", 26)
g:add_edge("file", "edition", 62)
g:add_edge("archive", "wash", 21)
g:add_edge("screw", "symptom", 75)
g:add_edge("house", "worth", 60)
g:add_edge("censorship", "left", 76)
g:add_edge("screw", "worth", 37)
g:add_edge("contact", "archive", 39)
g:add_edge("fix", "engine", 75)
g:add_edge("pressure", "negotiation", 28)
g:add_edge("hurt", "broken", 73)
g:add_edge("exclusive", "fleet", 18)
g:add_edge("chimpanzee", "basketball", 11)
g:add_edge("censorship", "engine", 65)
g:add_edge("hurt", "edition", 7)
g:add_edge("orchestra", "flawed", 31)
g:add_edge("regret", "freedom", 23)
g:add_edge("hurt", "fuel", 83)
g:add_edge("house", "screw", 8)
g:add_edge("charge", "danger", 71)
g:add_edge("fleet", "cage", 34)
g:add_edge("cage", "heavy", 20)
g:add_edge("chimpanzee", "humor", 32)
g:add_edge("house", "danger", 16)
g:add_edge("cage", "regulation", 27)
g:add_edge("chimpanzee", "intervention", 69)
g:add_edge("leaflet", "negotiation", 10)
g:add_edge("regulation", "archive", 13)
g:add_edge("negotiation", "promise", 91)
g:add_edge("quality", "house", 50)
g:add_edge("left", "beach", 20)
g:add_edge("engine", "danger", 26)
g:add_edge("left", "broken", 53)
g:add_edge("pressure", "danger", 23)
g:add_edge("reliable", "fuel", 31)
g:add_edge("charge", "workshop", 28)
g:add_edge("charge", "house", 46)
g:add_edge("house", "danger", 24)
g:add_edge("humor", "cage", 64)
g:add_edge("quality", "freedom", 89)
g:add_edge("so", "courage", 3)
g:add_edge("leaflet", "workshop", 25)
g:add_edge("orchestra", "courage", 26)
g:add_edge("leaflet", "regulation", 16)
g:add_edge("quality", "archive", 87)
g:add_edge("top", "workshop", 73)
g:add_edge("chimpanzee", "archive", 71)
g:add_edge("censorship", "broken", 62)
g:add_edge("engine", "cage", 77)
g:add_edge("heavy", "hurt", 42)
g:add_edge("medicine", "flawed", 82)
g:add_edge("archive", "symptom", 36)
g:add_edge("workshop", "fuel", 11)
g:add_edge("symptom", "promise", 92)
g:add_edge("orchestra", "cage", 35)
g:add_edge("compose", "promise", 12)
g:add_edge("pressure", "solve", 4)
g:add_edge("fuel", "humor", 6)
g:add_edge("engine", "freedom", 22)
g:add_edge("technique", "orchestra", 15)

local time = require("slang/time")
local n = 1000
local t0 = time.clock()
for(local i = 0; i < n; i = i + 1){
  queue = {}
  local result = g:dijkstra("fix")
}
local t1 = time.clock()
print("dijkstra x", n, ": ", (t1 - t0) * 1000, " ms\n")
