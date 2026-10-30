// Functional style in slang: the pipe operator (pipe.slang), holes
// (holes.slang) and multi-clause functions (def.slang), all loaded by this
// folder's slang.project. The end is Dijkstra's algorithm written with them.
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
local people = {
  {name: "Ada", age: 36},
  {name: "Grace", age: 45},
  {name: "Linus", age: 55},
}
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

// ------------------------------------------------------------ dijkstra
//
// Shortest paths in a purely functional style: no table below is ever
// changed after it is built; every step returns a new one, with `...`
// copying what stays the same. The pieces: a graph as a table from node
// to its edges, a queue kept sorted by distance, and `def` clauses that
// take the queue apart with matchers instead of loops and indices.

// a matcher is any value with a __match metamethod: it answers null for
// no match, or the value the rest of the pattern continues with
local func matcher(f){
  return {meta: {__match: func(self, v){ return f(v) }}}
}
local list = {
  // 'list.empty matches the empty list
  empty: matcher(=> len(_) == 0 and _ or null),
  // 'list.cons{first, rest} takes a non-empty list apart
  cons: matcher(func(l){
    if(len(l) == 0){ return null }
    local rest = {...l}
    remove(rest, 0)
    return {l[0], rest}
  }),
}

// the graph: node -> its edges, an edge being {to, weight}; an undirected
// edge is one in each direction
local func with_edge(graph, from, to, weight){
  return {...graph, [from]: {...(graph[from] or {}), {to, weight}}}
}
local func add_edge(graph, a, b, weight){
  return graph |> with_edge(a, b, weight) |> with_edge(b, a, weight)
}

// the queue: {node, distance} pairs sorted by distance; a node may sit in
// it more than once, the later entries are stale and skipped when popped
def enqueue('list.empty, entry){ return {entry} }
def enqueue('list.cons{first, rest}, entry) when(entry[1] < first[1]){ return {entry, first, ...rest} }
def enqueue('list.cons{first, rest}, entry){ return {first, ...enqueue(rest, entry)} }

// relaxing an edge out of `node`: a shorter way to its end replaces the
// end's distance and predecessor and queues it again
local INFINITY = 1 / 0
def relax({dist: dist, prev: prev, queue: queue}, node, {to, weight}) when(dist[node] + weight < (dist[to] or INFINITY)){
  local through = dist[node] + weight
  return {
    dist: {...dist, [to]: through},
    prev: {...prev, [to]: node},
    queue: enqueue(queue, {to, through}),
  }
}
def relax(state, _, _){ return state }

// the search settles the closest queued node, relaxes its edges and goes
// on with the queue that produced; three clauses: done, stale, settle
def search(graph, dist, prev, 'list.empty){ return {distance: dist, previous: prev} }
def search(graph, dist, prev, 'list.cons{{node, d}, rest}) when(d > dist[node]){ return search(graph, dist, prev, rest) }
def search(graph, dist, prev, 'list.cons{{node, d}, rest}){
  local next = graph[node]
    |> fold({dist: dist, prev: prev, queue: rest}, => relax(_, node, _2))
  return search(graph, next.dist, next.prev, next.queue)
}

def dijkstra(graph, start){ return search(graph, {[start]: 0}, {}, {{start, 0}}) }

// the path to a node, read back through the predecessors
def path(prev, node) when(prev[node] == null){ return {node} }
def path(prev, node){ return {...path(prev, prev[node]), node} }

local graph = {}
  |> add_edge("a", "b", 7)
  |> add_edge("a", "c", 9)
  |> add_edge("a", "f", 14)
  |> add_edge("b", "c", 10)
  |> add_edge("b", "d", 15)
  |> add_edge("c", "d", 11)
  |> add_edge("c", "f", 2)
  |> add_edge("d", "e", 6)
  |> add_edge("e", "f", 9)

let {distance: local distance, previous: local previous} = dijkstra(graph, "a")
show(distance, "distances from a")
path(previous, "e") |> str.join(" -> ") |> show("path a -> e")
path(previous, "d") |> str.join(" -> ") |> show("path a -> d")
