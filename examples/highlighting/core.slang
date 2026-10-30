// Core syntax: every token category the parser produces for plain slang.
// Open this file in VS Code with the slang extension installed; the colours
// come from the language server (the parser itself), not from a regex.
local greeting = "hello" // string
local count = 42 // number
local ratio = 2.5 // number
local flags = true // keyword constant

// keywords and punctuation
local func describe(name, n){
  if(n > 1){
    return concat(name, " x", n)
  } else if(n == 1){
    return name
  }
  return null
}

// operators
local total = (count + 1) * 2 - 3 / 4 % 5 ^ 2
local masked = count & 15 | 1 << 3 ~ ~0
local ok = total >= 0 and not(masked < 0) or false

// tables, patterns, loops
local items = {greeting, ratio, flags: flags, [count]: "computed"}
for(let local item in values(items)){
  print(describe(string(item), 1), "\n")
}
if(let {flags: local f} = items){
  print("flags: ", f, "\n")
}

// quotes and unquotes are code too
local tree = +{expr: 1 + 2}
local spliced = +{stat: print(-{tree}, "\n")}
print(type(tree), " ", type(spliced), "\n")
