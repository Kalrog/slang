// Code as data
//
// `+{expr: ...}` quotes code: you get its syntax tree as a table instead
// of running it. `-{...}` inside a quote splices a value in. `compile`
// turns source or a tree into a function. At the top level of a file,
// `-{block: ...}` runs while the file is being parsed.
local tree = +{expr: 1 + 2 * 3}
print(tree.type, " ", tree.op, "\n")

local n = +{expr: 10}
local f = compile(+{block: return -{n} * 2})
print(f(), "\n")

print(compile("return 6 * 7")(), "\n")
