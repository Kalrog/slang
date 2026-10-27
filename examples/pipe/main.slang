// Pipelines with |> (see pipe.slang; it is loaded by slang.project).
//     bin/slang run examples/pipe/main.slang
local str = require("slang/string")
local table = require("slang/table")

local func words(text){ return str.split(text, " ") }
local func lengths(list){ return table.map(list, func(w){ return len(w) }) }
local func sum(list){ return table.fold(list, 0, func(acc, n){ return acc + n }) }
local func clamp(n, low, high){
  if(n < low){ return low }
  if(n > high){ return high }
  return n
}

// a value flows through a chain of calls, each receiving it first
local total = "the quick brown fox jumps over the lazy dog"
  |> str.upper()
  |> words()
  |> lengths()
  |> sum()
print("letters: ", total, "\n")

// extra arguments go after the piped value: clamp(total * 2, 0, 50)
print("clamped: ", total * 2 |> clamp(0, 50), "\n")

// methods work too: the value becomes the first argument after self
local counter = {count: 0}
func counter.add(self, n, times){
  self.count = self.count + n * times
  return self.count
}
print("counter: ", 3 |> counter:add(2), "\n")

// a bare function on the right is called with the value
print("squared: ", 7 |> func(x){ return x * x }, "\n")
