# The pipe operator

`pipe.slang` adds Elixir's `|>` to slang in twenty lines: `x |> f(a)` is
`f(x, a)`, `x |> obj:m(a)` is `obj:m(x, a)`, left-associative, between
arithmetic and comparison in precedence. `slang.project` makes it ambient
for the folder, so `main.slang` uses it without an `extension` statement.

```
bin/slang run examples/pipe/main.slang
```
