// Functional style in slang: the pipe operator (pipe.slang) and holes
// (holes.slang), both loaded by this folder's slang.project.
//     bin/slang run examples/functional/main.slang
local str = require("slang/string")
local table = require("slang/table")
let {map: local map, filter: local filter, fold: local fold} = table

// the piped value arrives first, so the label comes second
local func show(v, label){ print(label, ": ", v, "\n") }

// a pipeline: each value flows into the first argument of the next call,
// and `_` writes the one-parameter functions without ceremony
local numbers = {1, 2, 3, 4, 5, 6, 7, 8}
numbers
  |> filter(_ % 2 == 0)
  |> map(_ * _)
  |> fold(0, _ + _2)
  |> show("sum of even squares")

// `str.upper(_.name)` alone would make `_.name` the function given to
// str.upper (the hole belongs to the nearest argument); `=>` moves the
// function out to the whole expression
local people = {{name: "Ada", age: 36}, {name: "Grace", age: 45}, {name: "Linus", age: 55}}
people
  |> filter(_.age > 40)
  |> map(=> str.upper(_.name))
  |> str.join(", ")
  |> show("over forty")

// a hole belongs to the nearest argument: here `_ + 1` is the function
// given to twice
local func twice(f, x){ return f(f(x)) }
show(twice(_ + 1, 5), "twice")

// `=> expr` claims every hole in expr, however deep; the function then
// spans the whole expression
local inc = func(x){ return x + 1 }
show(map({1, 2, 3}, => inc(_ * 10)), "arrow")
local average = => (_ + _2) / 2
show(average(3, 4), "average")
local answer = => 42
show(answer(), "thunk")

// inside an arrow every hole is the arrow's own, so a pipeline that needs
// its own small functions is written as an explicit function
local pipeline = func(xs){
  return xs |> map(_ * 2) |> fold(0, _ + _2)
}
show(pipeline({1, 2, 3}), "pipeline")

// multi-clause functions (def.slang): every parameter is a pattern, the
// clauses are tried in order, `when` adds a guard, `...rest` collects
def fact(0){ return 1 }
def fact(n) when(n > 0){ return n * fact(n - 1) }
show(fact(10), "fact")

local Circle = {meta: {__type: "Circle"}, radius: 2}
def area('Circle{radius: r}){ return 3 * r * r }
def area({w, h}){ return w * h }
def area(_){ return "not a shape" }
show({area(Circle), area({4, 5}), area("x")}, "area")

def total(){ return 0 }
def total(first, ...rest){ return first + total(...rest) }
show(total(1, 2, 3, 4), "total")

def greet("en", name){ return concat("hello ", name) }
def greet("de", name){ return concat("hallo ", name) }
show(greet("de", "welt"), "greet")
// local failed = pcall(greet, "fr", "monde")
// show(failed[1].message, "no clause")

local func matcher(f){
  return {meta:{__match:func(self,v){return f(v)}}}
}

local head_rest = matcher(func(v){
    if(len(list) > 0){
      if (len(list) == 1){
        return {list[0]}
      }
      local copy = {...v}
      remove(copy,0)
      return {list[0],copy}
    }
    return null
  })


local INFINITY = 10000000;

local func make_graph(){
  return {
    nodes: {},
    edges: {}
  }
}

local func add_edge(graph,node1,node2,weight){
  local connection = {node1,node2,weight}
  return {
    nodes: {
      [node1]: {connection,...(graph[node1] or {})},
      [node2]: {connection,...(graph[node2] or {})},
      ...graph.nodes
    },
    edges:{
      connection,
      ...graph.edges
    }
  }
}

local graph = make_graph() 
  |> add_edge("a","b",100)
  |> add_edge("b","c",100)
  |> add_edge("a","c",50)

local distance = graph.nodes
  |> table.keys()
  |> fold({},=>{..._,[_2]:INFINITY})

print(distance)


def dijkstra(graph,start){
  local dist = graph.nodes
    |> table.keys()
    |> fold({},=>{..._,[_2]:INFINITY})
  local prev = {}
  local queue = {start}
  for(let local node in keys(graph.nodes)){
    dist[node] = INFINITY;
  }
  dist[start] = 0;
  return dijkstra(graph,start,dist,prev,queue)
}


def dijkstra(graph,start,dist,prev,{}){
  return {distance:dist,previous:prev}
}

def dijkstra(graph,start,dist,prev,'(head_rest){node, rest}){

}
