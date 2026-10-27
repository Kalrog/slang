# Functional style

Two extensions that give slang a functional flavour, written against the
grammar API, and a `slang.project` that makes them ambient in this folder.

- `pipe.slang`: Elixir's `|>` in twenty lines. `x |> f(a)` is `f(x, a)`,
  `x |> obj:m(a)` is `obj:m(x, a)`, left-associative, between arithmetic
  and comparison.
- `holes.slang`: `_` (and `_2`, `_3`) for the parameters of an unwritten
  function. A hole belongs to the nearest `=> expr`, or without one to the
  nearest enclosing argument: `map(t, _ + 5)`, `fold(t, 0, _ + _2)`,
  `map(t, => inc(_ * 10))`. `=> 42` is a thunk. Outside both, `_` is an
  ordinary variable.

```
bin/slang run examples/functional/main.slang
```

`main.slang` pipes a list through filter, map and fold with holes, and
`test/functional_test.slang` pins the rules down (nesting in both
directions, several holes, arrows inside arrows).
