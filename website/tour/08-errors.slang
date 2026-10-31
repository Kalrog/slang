// Errors
//
// `error(...)` raises an error with a message; `raise(value)` raises any
// value, often a table describing what went wrong. `try` runs a block and
// its `catch` clauses take patterns: the first one that matches handles
// the error, and an error no clause matches goes on up.
//
// `defer` runs code when the block it is in ends, however it ends.
local func load(path){
  if(path == ""){
    raise({kind: "invalid", reason: "empty path"})
  }
  error("cannot open ", path)
}

for(let local path in values({"", "notes.txt"})){
  try {
    defer print("  (done with '", path, "')\n")
    load(path)
  } catch({kind: "invalid", reason: local why}) {
    print("invalid: ", why, "\n")
  } catch(local e) {
    print("failed: ", e.message, "\n")
  }
}

local r = pcall(error, "boom")
print(r[0], " ", r[1].message, "\n")
