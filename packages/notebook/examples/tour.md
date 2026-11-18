# A tour of notebooks

This is a notebook: a Markdown file whose `slang` blocks are cells. Run a
cell with shift+enter, or all of them with **Run all**.

## Cells share a session

A cell's top-level locals stay for the cells after it, and a cell that
ends in an expression shows its value.

```slang
local squares = {}
for(local i = 1; i <= 10; i = i + 1){
  append(squares, i * i)
}
squares
```

```slang
local func sum(list){
  local total = 0
  for(let local v in values(list)){
    total = total + v
  }
  return total
}
sum(squares)
```

What a cell prints is shown too, and tables are trees to unfold:

```slang
print("the largest is ", squares[len(squares) - 1], "\n")
{name: "squares", count: len(squares), first: {squares[0], squares[1], squares[2]}}
```

## Showing more than text

The module `notebook` makes plots, tables, sound and markup.

```slang
local nb = require("notebook")
local math = require("slang/math")

local note = {}
local rate = 8000
for(local i = 0; i < rate; i = i + 1){
  local t = i / rate
  append(note, math.sin(t * 440 * 2 * 3.14159265) * math.exp(-t * 4))
}
nb.display(nb.plot(note, {title: "A plucked note", x_label: "sample"}))
nb.audio(note, {rate: rate})
```

```slang
local rows = {}
for(local i = 0; i < 5; i = i + 1){
  append(rows, {n: i, square: squares[i], root: math.sqrt(squares[i])})
}
nb.table(rows, {columns: {"n", "square", "root"}})
```

Several series, as lines and bars:

```slang
local odd = {}
local even = {}
for(local i = 0; i < len(squares); i = i + 1){
  append(odd, squares[i] % 7)
  append(even, squares[i] % 5)
}
nb.plot({
  {y: odd, label: "mod 7", kind: "bar"},
  {y: even, label: "mod 5", kind: "bar"},
  {y: squares, label: "squares"},
}, {title: "Squares and their remainders", y_max: 100})
```

Markup of your own, and Markdown:

```slang
nb.display(nb.markdown(concat("The sum of the squares is **", string(sum(squares)), "**.")))
nb.html("<p style=\"font-size: 28px; margin: 0\">&#9834; &#9835; &#9834;</p>")
```

## Errors

An error shows where it happened; the cells after it are not run by
**Run all**.

```slang
local func depth(n){
  if(n == 0){
    raise(error.new(error.kinds.argument, "too deep"))
  }
  return depth(n - 1)
}
depth(3)
```
