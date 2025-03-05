local foo = {
    type: "Foo",
    bar: 42,
}

local bar = {
    type: "Bar",
    fooBar: 12,
}

bar.meta = {
    "__index": foo,
}

assert(bar.bar == 42, "metatable get table (__index) correctly")
assert(bar.fooBar == 12, "metatable get normal table value correctly")

if(not let{type: "Bar", bar: 42} = bar){
  assert(false, "should never reach here")
}