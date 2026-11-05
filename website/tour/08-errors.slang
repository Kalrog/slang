// Errors
//
// `raise(value)` raises an error. An error is a table: `error.new(kind,
// message, fields)` makes one, where the kind is what code catches on
// (the shared ones are in `error.kinds`) and the fields carry details.
// `try` runs a block and its `catch` clauses take patterns: the first one
// that matches handles the error, and an error no clause matches goes on
// up. `^expr` in a pattern compares with a value instead of binding.
//
// `defer` runs code when the block it is in ends, however it ends.
local stock = {apples: 3}

local func take(name, n){
  if(n <= 0){
    raise(error.new(error.kinds.argument, "take at least one", {n: n}))
  }
  local have = stock[name]
  if(have == null){
    raise(error.new(error.kinds.not_found, concat("no ", name), {name: name}))
  }
  stock[name] = have - n
  return have - n
}

for(let local order in values({{"apples", 1}, {"pears", 2}, {"apples", 0}})){
  try {
    defer print("  (done with ", order[0], ")\n")
    print("left: ", take(order[0], order[1]), "\n")
  } catch({kind: ^error.kinds.not_found, name: local name}) {
    print("we have no ", name, "\n")
  } catch(local e) {
    print(e.kind, ": ", e.message, "\n")
  }
}

// try is an expression too: a value, or the catch's when it raises
local left = try { take("pears", 1) } catch { 0 }
print("pears left: ", left, "\n")

// error.wrap adds context and keeps the kind; error.message joins them
local e = try { take("plums", 1) } catch(local e) { error.wrap(e, "the order") }
print(error.message(e), " (", e.kind, ")\n")
